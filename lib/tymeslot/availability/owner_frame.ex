defmodule Tymeslot.Availability.OwnerFrame do
  @moduledoc """
  The owner's timezone and hours in effect on a single date.

  One function answers "which clock is the owner on, and which hours do they
  offer, on date D". `BusinessHours.get_business_hours_in_timezone/5` calls it,
  and because every availability path — the booking page's slot list, the month
  grid, the range availability map and the booking-time re-check in
  `Tymeslot.Bookings.ScheduleCheck` — resolves a day's window through that one
  function, all of them inherit travel periods without each having to remember
  to. That is deliberate: the offered slots and the re-check that validates a
  submission must never disagree.

  Named for the "owner frame" vocabulary `Tymeslot.Availability.TimeSlots`
  already uses for the owner-side date a window was read for.

  `day` is `nil` when no trip covers the date. The `nil` is what lets
  `BusinessHours` keep its own private weekly lookup as the non-trip path,
  rather than this module needing a `schedule_id` and duplicating that logic.

  Trips are read from `config[:travel_periods]` when a caller prefetched them,
  and otherwise queried per date using `config[:profile_id]` — the same
  prefetch-or-query fallback `BusinessHours.lookup_override/3` and
  `lookup_day_availability/3` already use, so a caller that cannot prefetch
  still gets correct answers.
  """

  alias Tymeslot.Availability.Travel

  @type t :: %{
          timezone: String.t(),
          day: map() | nil,
          source: :travel | :schedule
        }

  @doc """
  The zone and hours in effect on `date`.

  `owner_timezone` is the owner's *home* zone — the fallback used whenever no
  trip covers the date. It is not necessarily the effective zone, which is this
  function's whole purpose.
  """
  @spec for_date(Date.t(), String.t(), map()) :: t()
  def for_date(date, owner_timezone, config) do
    case covering_period(date, config) do
      nil ->
        %{timezone: owner_timezone, day: nil, source: :schedule}

      period ->
        %{timezone: period.timezone, day: day_for(period, date), source: :travel}
    end
  end

  # An explicit list wins, including an empty one: a caller that prefetched a
  # window has already established there are no trips in it, and re-querying
  # would undo the prefetch's whole purpose.
  defp covering_period(date, %{travel_periods: periods}) when is_list(periods) do
    Enum.find(periods, &covers?(&1, date))
  end

  defp covering_period(date, %{profile_id: profile_id}) when is_integer(profile_id) do
    profile_id
    |> Travel.for_window(date, date)
    |> Enum.find(&covers?(&1, date))
  end

  defp covering_period(_date, _config), do: nil

  defp covers?(period, date) do
    Date.compare(date, period.start_date) != :lt and
      Date.compare(date, period.end_date) != :gt
  end

  defp day_for(period, date) do
    day_of_week = Date.day_of_week(date)

    # An unloaded association reads as no hours, so a trip whose days failed to
    # preload offers nothing rather than falling back to home hours interpreted
    # in a foreign zone — which would offer the wrong times, not merely fewer.
    days = if is_list(period.days), do: period.days, else: []

    case Enum.find(days, &(&1.day_of_week == day_of_week)) do
      nil ->
        unavailable(day_of_week)

      day ->
        %{
          is_available: day.is_available,
          day_of_week: day_of_week,
          start_time: day.start_time,
          end_time: day.end_time,
          breaks: []
        }
    end
  end

  defp unavailable(day_of_week) do
    %{
      is_available: false,
      day_of_week: day_of_week,
      start_time: nil,
      end_time: nil,
      breaks: []
    }
  end
end
