defmodule Tymeslot.Availability.TravelQueryBudgetTest do
  @moduledoc """
  What the trip-aware paths cost, and which window they ask for.

  `Tymeslot.Availability.OwnerFrame` answers from a prefetched
  `:travel_periods` list when a caller has one and queries per date when it
  only has `:profile_id`, so every path that walks dates has to prefetch or pay
  a lookup per day. These tests count the lookups rather than the answers — the
  answers are the gate test's subject — and pin the padded window each call
  site asks for, because a window narrower than the dates the slot engine reads
  would resolve a trip starting the next day as no trip at all.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :availability
  @moduletag :integration

  import Tymeslot.Factory

  alias Tymeslot.Availability.Calculate
  alias Tymeslot.Availability.Travel
  alias Tymeslot.Bookings.Policy
  alias TymeslotWeb.Live.Scheduling.AvailabilityHelpers
  alias TymeslotWeb.Live.Scheduling.CalendarHelpers

  @home "America/New_York"
  @away "Europe/Berlin"

  # A Wednesday at least `days_ahead` out, so the test never rots as the clock
  # moves and never depends on a hard-coded year.
  defp wednesday_at_least(days_ahead) do
    base = Date.add(Date.utc_today(), days_ahead)
    Date.add(base, rem(10 - Date.day_of_week(base), 7))
  end

  setup do
    user = insert(:user)
    profile = insert(:profile, user: user, timezone: @home)

    schedule =
      insert(:availability_schedule,
        profile: profile,
        is_default: true,
        buffer_minutes: 0,
        min_advance_hours: 0,
        advance_booking_days: 365
      )

    for day_of_week <- 1..5 do
      insert(:weekly_availability,
        schedule: schedule,
        day_of_week: day_of_week,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )
    end

    meeting_type =
      insert(:meeting_type,
        user: user,
        duration_minutes: 30,
        availability_schedule_id: schedule.id
      )

    in_trip = wednesday_at_least(60)
    after_trip = Date.add(in_trip, 14)

    {:ok, trip} =
      Travel.create_period(profile, %{
        label: "Berlin",
        start_date: Date.add(in_trip, -2),
        end_date: Date.add(in_trip, 2),
        timezone: @away
      })

    {:ok, _day} =
      Travel.set_day(profile, trip, %{
        day_of_week: 3,
        is_available: true,
        start_time: ~T[10:00:00],
        end_time: ~T[16:00:00]
      })

    %{
      user: user,
      profile: profile,
      schedule: schedule,
      meeting_type: meeting_type,
      in_trip: in_trip,
      after_trip: after_trip
    }
  end

  describe "the grid's business-hours fallback" do
    # Both grids answer from business hours until the conflict-aware map
    # arrives. Now that `business_day?/3` consults the owner frame, a
    # trip-blind config paints a weekday the trip has closed as bookable.
    # `in_trip + 1` is the Thursday inside the trip, which the trip does not
    # offer and the home schedule does — so it separates the two answers.
    test "the month grid greys a weekday the trip does not offer", ctx do
      days =
        CalendarHelpers.get_calendar_days(
          @home,
          ctx.in_trip.year,
          ctx.in_trip.month,
          ctx.profile,
          nil,
          ctx.meeting_type
        )

      available = Map.new(days, &{&1.date, &1.available})

      assert available[Date.to_string(ctx.in_trip)] == true
      assert available[Date.to_string(Date.add(ctx.in_trip, 1))] == false
    end

    test "the week strip greys a weekday the trip does not offer", ctx do
      available =
        ctx.in_trip
        |> Date.beginning_of_week()
        |> CalendarHelpers.get_week_days(ctx.profile, nil, @home, ctx.meeting_type)
        |> Map.new(&{&1.date, &1.available})

      assert available[Date.to_string(ctx.in_trip)] == true
      assert available[Date.to_string(Date.add(ctx.in_trip, 1))] == false
    end
  end

  describe "trip lookups per fetch" do
    test "a slot check runs one trip query, not one per adjacent day", ctx do
      config = Policy.scheduling_config(ctx.user.id, ctx.meeting_type)

      # `BusinessHours` resolves `date - 1`, `date` and `date + 1`, each of
      # which reaches `OwnerFrame`; without the prefetch beside
      # `prefetch_schedule_data/4` that is three queries for one slot check.
      count =
        count_trip_queries(ctx.profile.id, fn ->
          {:ok, slots} =
            Calculate.available_slots(ctx.in_trip, 30, @home, config.owner_timezone, [], config)

          refute slots == []
        end)

      assert count == 1
    end

    test "a range runs one trip query for the whole window, not one per day", ctx do
      config = Policy.scheduling_config(ctx.user.id, ctx.meeting_type)

      count =
        count_trip_queries(ctx.profile.id, fn ->
          {:ok, availability} =
            Calculate.range_availability(
              ctx.in_trip,
              Date.add(ctx.in_trip, 20),
              @home,
              @home,
              [],
              config
            )

          assert map_size(availability) == 21
        end)

      assert count == 1
    end

    test "the month grid runs one trip query for the whole grid", ctx do
      config = %{
        schedule_id: ctx.schedule.id,
        max_advance_booking_days: 365,
        min_advance_hours: 0,
        buffer_minutes: 0,
        duration_minutes: 30,
        owner_timezone: @home,
        profile_id: ctx.profile.id
      }

      # The business-hours fallback answers all 42 cells, so this is the site
      # where a per-date lookup would be worst.
      count =
        count_trip_queries(ctx.profile.id, fn ->
          days =
            Calculate.get_calendar_days(@home, ctx.in_trip.year, ctx.in_trip.month, config, nil)

          refute days == []
        end)

      assert count == 1
    end

    test "the booking page's range fetch runs one trip query for the whole window", ctx do
      count =
        count_trip_queries(ctx.profile.id, fn ->
          {:ok, _availability} =
            AvailabilityHelpers.get_range_availability(
              ctx.user.id,
              ctx.in_trip,
              Date.add(ctx.in_trip, 20),
              @home,
              ctx.profile,
              context(ctx),
              30
            )
        end)

      assert count == 1
    end

    test "the week strip runs one trip query for the whole week", ctx do
      count =
        count_trip_queries(ctx.profile.id, fn ->
          week_start = Date.beginning_of_week(ctx.in_trip)

          days =
            CalendarHelpers.get_week_days(week_start, ctx.profile, nil, @home, ctx.meeting_type)

          assert Enum.count(days) == 7
        end)

      assert count == 1
    end

    test "the slot-list call site asks for a window padded by a day at each end", ctx do
      [params] =
        trip_queries(ctx.profile.id, fn ->
          {:ok, _slots} =
            AvailabilityHelpers.get_available_slots(
              Date.to_iso8601(ctx.in_trip),
              30,
              @home,
              ctx.user.id,
              ctx.profile,
              context(ctx)
            )
        end)

      assert window(params) == {Date.add(ctx.in_trip, -1), Date.add(ctx.in_trip, 1)}
    end

    test "the calendar-range call site asks for a window padded by a day at each end", ctx do
      last_date = Date.add(ctx.in_trip, 6)

      [params] =
        trip_queries(ctx.profile.id, fn ->
          {:ok, _availability} =
            AvailabilityHelpers.get_range_availability(
              ctx.user.id,
              ctx.in_trip,
              last_date,
              @home,
              ctx.profile,
              context(ctx),
              30
            )
        end)

      assert window(params) == {Date.add(ctx.in_trip, -1), Date.add(last_date, 1)}
    end

    test "a prefetched list wins, so no second lookup runs", ctx do
      count =
        count_trip_queries(ctx.profile.id, fn ->
          config =
            Calculate.prefetch_travel_periods(
              %{travel_periods: [], profile_id: ctx.profile.id},
              ctx.profile.id,
              ctx.in_trip,
              ctx.in_trip
            )

          assert config.travel_periods == []
        end)

      assert count == 0
    end
  end

  # The inclusive window a trip lookup asked for. `list_overlapping/3` binds the
  # two dates in comparison order rather than chronological order, so they are
  # read as a sorted pair.
  defp window(params) do
    [first, last] = params |> Enum.filter(&match?(%Date{}, &1)) |> Enum.sort(Date)
    {first, last}
  end

  defp count_trip_queries(profile_id, fun), do: length(trip_queries(profile_id, fun))

  # The bound parameters of every trip lookup `fun` makes, filtered by this
  # profile's id so a test running beside this one cannot inflate the count.
  # The `:days` preload rides along on the same lookup and reads from
  # `travel_period_days`, so it is not counted as a second trip query.
  defp trip_queries(profile_id, fun) do
    handler_id = {__MODULE__, make_ref()}
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:tymeslot, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if metadata[:source] == "travel_periods" and
             profile_id in List.wrap(metadata[:params]) do
          send(test_pid, {handler_id, List.wrap(metadata[:params])})
        end
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    drain_trip_queries(handler_id)
  end

  defp drain_trip_queries(handler_id, acc \\ []) do
    receive do
      {^handler_id, params} -> drain_trip_queries(handler_id, [params | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # The calendar seam the flow already has for tests: a one-argument function
  # stands in for the provider, so this asks nothing of the calendar layer.
  defp context(ctx) do
    %{
      demo_mode: false,
      organizer_profile: ctx.profile,
      meeting_type: ctx.meeting_type,
      debug_calendar_module: fn _organizer_user_id -> {:ok, []} end
    }
  end
end
