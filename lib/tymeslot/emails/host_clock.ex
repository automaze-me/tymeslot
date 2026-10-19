defmodule Tymeslot.Emails.HostClock do
  @moduledoc """
  The clock a host reads their booking emails by: their timezone and their
  chosen 12- or 24-hour format. A user's own account emails read by the same
  clock (`for_user/2`, `format_datetime/3`).

  Resolved once per email from the meeting's organiser, for the
  host-addressed templates that render straight from a meeting rather than
  from `Tymeslot.Emails.AppointmentBuilder`'s payload. The payload resolves
  the same clock when it is built: the start and end already shifted into
  the host's zone (`:start_time_owner_tz`, `:end_time_owner_tz`) and their
  chosen format as `:organizer_time_format`. An organiser-less meeting reads
  in the platform default timezone and the locale's own clock.
  """

  alias Tymeslot.Availability.Travel
  alias Tymeslot.CalendarGrid
  alias Tymeslot.Emails.Shared.Formatting
  alias Tymeslot.Profiles
  alias Tymeslot.Utils.DateTimeUtils

  @type t :: %{timezone: String.t(), time_format: String.t() | nil}

  @doc """
  The host clock for `meeting`'s organiser. `locale` is the email's, which
  decides the clock when the host never chose one.
  """
  @spec for_meeting(map(), String.t()) :: t()
  def for_meeting(meeting, locale),
    do: %{timezone: timezone(meeting), time_format: time_format(meeting, locale)}

  @doc """
  The clock `user_id` reads their own account emails by: the same timezone and
  12- or 24-hour choice as their booking emails.
  """
  @spec for_user(integer(), String.t()) :: t()
  def for_user(user_id, locale), do: for_meeting(%{organizer_user_id: user_id}, locale)

  @doc """
  `datetime` as an email to `user_id` states a time: on their own clock, with
  the zone named.
  """
  @spec format_datetime(DateTime.t(), integer(), String.t()) :: String.t()
  def format_datetime(%DateTime{} = datetime, user_id, locale) do
    clock = for_user(user_id, locale)

    datetime
    |> DateTimeUtils.convert_to_timezone(clock.timezone)
    |> Formatting.format_datetime(locale, clock.time_format)
  end

  @doc """
  The organiser's timezone alone, for a sender that needs no clock format.

  A meeting with a start is read in the zone the host is in on its own date:
  a travel period covering that date wins over the profile's zone
  (`Travel.for_window/3`), so a February booking for a March trip is
  announced in the zone the host will be in when it happens. The date is read
  in the host's home zone, not UTC: UTC would now and then roll it to the day
  before or after the host's own wall-clock day and pick the wrong trip at a
  trip's edge. A meeting within a few hours of midnight on a trip's first or
  last day can still land on the adjacent date where the two zones' days
  disagree.
  """
  @spec timezone(map()) :: String.t()
  def timezone(%{organizer_user_id: nil}), do: Profiles.get_default_timezone()

  def timezone(%{organizer_user_id: user_id, start_time: %DateTime{} = start_time}) do
    case Profiles.get_profile_by_user_id(user_id) do
      {:ok, profile} -> timezone_on_meeting_date(profile, start_time)
      {:error, :not_found} -> Profiles.get_default_timezone()
    end
  end

  def timezone(%{organizer_user_id: user_id}), do: Profiles.get_user_timezone(user_id)
  def timezone(_meeting), do: Profiles.get_default_timezone()

  defp timezone_on_meeting_date(profile, start_time) do
    home_timezone = Profiles.timezone(profile)

    meeting_date =
      start_time |> DateTimeUtils.convert_to_timezone(home_timezone) |> DateTime.to_date()

    case Travel.for_window(profile.id, meeting_date, meeting_date) do
      [%{timezone: trip_timezone} | _rest] -> trip_timezone
      [] -> home_timezone
    end
  end

  @doc """
  The organiser's profile zone, whatever trip covers the meeting's date: for a
  fallback shown to the attendee, which must not move because the host travels.
  """
  @spec home_timezone(map()) :: String.t()
  def home_timezone(%{organizer_user_id: nil}), do: Profiles.get_default_timezone()
  def home_timezone(%{organizer_user_id: user_id}), do: Profiles.get_user_timezone(user_id)
  def home_timezone(_meeting), do: Profiles.get_default_timezone()

  @doc """
  The organiser's 12- or 24-hour choice alone, or nil (the locale's own
  clock) for an organiser-less meeting.
  """
  @spec time_format(map(), String.t()) :: String.t() | nil
  def time_format(%{organizer_user_id: nil}, _locale), do: nil

  def time_format(%{organizer_user_id: user_id}, locale),
    do: CalendarGrid.get_user_time_format(user_id, locale)

  def time_format(_meeting, _locale), do: nil
end
