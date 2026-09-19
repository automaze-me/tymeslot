defmodule Tymeslot.Availability.Travel do
  @moduledoc """
  Travel periods: the date ranges during which a profile's timezone and hours
  differ. The sibling of `Tymeslot.Availability.Schedules`.

  `for_window/3` is the single trip resolver, called by both
  `Tymeslot.Bookings.Policy.scheduling_config/2` (the submit path) and the
  booking page's display path. Having one resolver is what makes the two paths
  structurally unable to disagree about which trips apply — the same reason
  `Policy.slot_interval_minutes/1` exists.

  `timezone_on/2` and `timezone_for_user_on/2` are the display-side
  counterpart: which zone a profile (or a booking's organiser) is on for a
  given date, used by the dashboard grid and by host-facing emails rather
  than by the availability engine.

  Every write takes the profile struct rather than a profile id, because the
  availability cache is keyed by user and the struct already carries
  `user_id`. Deriving it from the id would mean an extra query, or a query
  module reaching into another domain's schema.

  Non-overlap is enforced here rather than by a database exclusion constraint:
  the rigorous form needs the `btree_gist` extension, which some managed
  Postgres will not grant a non-superuser, and Core ships to self-hosters. The
  race window is one person editing their own trips.
  """

  alias Ecto.Changeset
  alias Tymeslot.Availability.TravelPeriodDaySchema
  alias Tymeslot.Availability.TravelPeriodQueries
  alias Tymeslot.Availability.TravelPeriodSchema
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Profiles.ProfileSchema

  @doc """
  Trips overlapping an inclusive date window, `:days` preloaded.
  """
  @spec for_window(integer(), Date.t(), Date.t()) :: [TravelPeriodSchema.t()]
  defdelegate for_window(profile_id, start_date, end_date),
    to: TravelPeriodQueries,
    as: :list_overlapping

  @doc """
  The zone the profile is on for a given date: the covering trip's zone, else
  the profile's own.

  The date matters, and which date to pass depends on the question being
  asked. "What time is it for me now" — the dashboard grid, desktop reminders
  — passes today. "When will this meeting be for me" — host-facing emails —
  passes the meeting's own date, so a booking made at home for a date abroad
  is announced in the zone the host will actually be in.

  This lives here rather than in `Tymeslot.Profiles.Timezone` — that module's
  moduledoc restricts it to pure, Phoenix/LiveView-free helpers, and it holds
  only `prefill_timezone/2`; a resolver that reads trips from the database
  does not fit there. It also stays out of `profiles.ex` itself: this fork
  rebases against upstream indefinitely, so new behaviour prefers a new file
  with no conflict surface over an edit to a hot, frequently-changed one.
  Trips are read directly rather than through a prefetched
  `availability_config`, because this resolver's callers (emails, the
  dashboard grid) have no schedule context to prefetch alongside.
  """
  @spec timezone_on(ProfileSchema.t(), Date.t()) :: String.t()
  def timezone_on(%ProfileSchema{} = profile, %Date{} = date) do
    case TravelPeriodQueries.list_overlapping(profile.id, date, date) do
      [period | _rest] -> period.timezone
      [] -> profile.timezone || Profiles.get_default_timezone()
    end
  end

  @doc """
  `timezone_on/2` for a caller that holds only a user id, such as an email
  builder working from `meeting.organizer_user_id`. A `nil` id (an
  unattributed meeting) and a user with no profile both resolve to the
  default zone rather than raising.
  """
  @spec timezone_for_user_on(integer() | nil, Date.t()) :: String.t()
  def timezone_for_user_on(nil, %Date{}), do: Profiles.get_default_timezone()

  def timezone_for_user_on(user_id, %Date{} = date) do
    case ProfileQueries.get_by_user_id(user_id) do
      {:ok, profile} -> timezone_on(profile, date)
      {:error, :not_found} -> Profiles.get_default_timezone()
    end
  end

  @doc """
  Every trip a profile owns, earliest first.
  """
  @spec list_for_profile(integer()) :: [TravelPeriodSchema.t()]
  defdelegate list_for_profile(profile_id),
    to: TravelPeriodQueries,
    as: :list_by_profile

  @doc """
  Creates a trip for a profile, refusing one that overlaps an existing trip.
  """
  @spec create_period(ProfileSchema.t(), map()) ::
          {:ok, TravelPeriodSchema.t()} | {:error, Ecto.Changeset.t()}
  def create_period(%ProfileSchema{} = profile, attrs) do
    %TravelPeriodSchema{}
    |> TravelPeriodSchema.changeset(Map.put(normalise(attrs), :profile_id, profile.id))
    |> reject_overlap(profile.id, nil)
    |> TravelPeriodQueries.insert_period()
    |> invalidate(profile)
  end

  @doc """
  Updates a trip, refusing a change that would overlap another trip.
  """
  @spec update_period(ProfileSchema.t(), TravelPeriodSchema.t(), map()) ::
          {:ok, TravelPeriodSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_period(%ProfileSchema{} = profile, %TravelPeriodSchema{} = period, attrs) do
    period
    |> TravelPeriodSchema.changeset(normalise(attrs))
    |> reject_foreign_profile(profile, period)
    |> reject_overlap(profile.id, period.id)
    |> TravelPeriodQueries.update_period()
    |> invalidate(profile)
  end

  @doc """
  Deletes a trip and its days.
  """
  @spec delete_period(ProfileSchema.t(), TravelPeriodSchema.t()) ::
          {:ok, TravelPeriodSchema.t()} | {:error, Ecto.Changeset.t()}
  def delete_period(%ProfileSchema{} = profile, %TravelPeriodSchema{} = period) do
    period
    |> TravelPeriodQueries.delete_period()
    |> invalidate(profile)
  end

  @doc """
  Sets one weekday's hours within a trip, replacing any already stored.
  """
  @spec set_day(ProfileSchema.t(), TravelPeriodSchema.t(), map()) ::
          {:ok, TravelPeriodDaySchema.t()} | {:error, Ecto.Changeset.t()}
  def set_day(%ProfileSchema{} = profile, %TravelPeriodSchema{} = period, attrs) do
    attrs
    |> normalise()
    |> Map.put(:travel_period_id, period.id)
    |> TravelPeriodQueries.upsert_day()
    |> invalidate(profile)
  end

  # Accepts either string or atom keys, so a LiveView form's params and a
  # direct caller's map both work without each call site converting.
  # Whitelisted rather than converted with `String.to_existing_atom/1`: a
  # `phx-change` payload carries LiveView's own `_unused_*` keys, which are
  # not existing atoms, and would raise instead of being ignored.
  @known_fields ~w(label start_date end_date timezone day_of_week is_available start_time end_time)a

  defp normalise(attrs) do
    Enum.reduce(@known_fields, %{}, fn field, acc ->
      string_field = Atom.to_string(field)

      cond do
        Map.has_key?(attrs, field) -> Map.put(acc, field, Map.fetch!(attrs, field))
        Map.has_key?(attrs, string_field) -> Map.put(acc, field, Map.fetch!(attrs, string_field))
        true -> acc
      end
    end)
  end

  defp reject_foreign_profile(%Changeset{valid?: false} = changeset, _profile, _period),
    do: changeset

  defp reject_foreign_profile(changeset, %ProfileSchema{id: profile_id}, %TravelPeriodSchema{
         profile_id: profile_id
       }),
       do: changeset

  defp reject_foreign_profile(changeset, _profile, _period) do
    Changeset.add_error(changeset, :base, "does not belong to this profile")
  end

  defp reject_overlap(%Changeset{valid?: false} = changeset, _profile_id, _exclude_id),
    do: changeset

  defp reject_overlap(changeset, profile_id, exclude_id) do
    start_date = Changeset.get_field(changeset, :start_date)
    end_date = Changeset.get_field(changeset, :end_date)

    case TravelPeriodQueries.overlapping(profile_id, start_date, end_date, exclude_id) do
      [] ->
        changeset

      [_conflict | _rest] ->
        Changeset.add_error(changeset, :start_date, "overlaps an existing trip")
    end
  end

  # Availability for every one of this user's meeting types can change when a
  # trip does, so the whole user's cache goes rather than any narrower key.
  # The profile struct already carries `user_id`, so invalidation reads it
  # directly rather than walking profile -> user through another query
  # module, the way `Schedules.invalidate_cache/2` must when it is only
  # handed a profile id. `AvailabilityCache.invalidate_for_user/1` treats a
  # nil user id as a no-op, so this can never turn a successful write into an
  # error.
  defp invalidate({:ok, _record} = result, %ProfileSchema{user_id: user_id}) do
    AvailabilityCache.invalidate_for_user(user_id)
    result
  end

  defp invalidate({:error, _changeset} = result, _profile), do: result
end
