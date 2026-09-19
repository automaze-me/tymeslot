defmodule Tymeslot.Availability.Travel do
  @moduledoc """
  Travel periods: the date ranges during which a profile's timezone and hours
  differ. The sibling of `Tymeslot.Availability.Schedules`.

  `for_window/3` is the single trip resolver, called by both
  `Tymeslot.Bookings.Policy.scheduling_config/2` (the submit path) and the
  booking page's display path. Having one resolver is what makes the two paths
  structurally unable to disagree about which trips apply — the same reason
  `Policy.slot_interval_minutes/1` exists.

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
  alias Tymeslot.Profiles.ProfileSchema

  @doc """
  Trips overlapping an inclusive date window, `:days` preloaded.
  """
  @spec for_window(integer(), Date.t(), Date.t()) :: [TravelPeriodSchema.t()]
  defdelegate for_window(profile_id, start_date, end_date),
    to: TravelPeriodQueries,
    as: :list_overlapping

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
  defp normalise(attrs) do
    Map.new(attrs, fn
      {key, value} when is_binary(key) -> {String.to_existing_atom(key), value}
      {key, value} -> {key, value}
    end)
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
