defmodule Tymeslot.Availability.TravelPathAgreementTest do
  use Tymeslot.DataCase, async: true

  @moduletag :availability
  @moduletag :integration

  import Tymeslot.Factory

  alias Tymeslot.Availability.Calculate
  alias Tymeslot.Availability.Travel
  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Bookings.ScheduleCheck
  alias Tymeslot.Utils.DateTimeUtils
  alias TymeslotWeb.Live.Scheduling.AvailabilityHelpers

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

  describe "the submit path" do
    test "carries the profile id so trips resolve", ctx do
      config = Policy.scheduling_config(ctx.user.id, ctx.meeting_type)

      assert config.profile_id == ctx.profile.id
      assert config.owner_timezone == @home
    end

    test "offers trip hours for a date inside the trip", ctx do
      config = Policy.scheduling_config(ctx.user.id, ctx.meeting_type)

      {:ok, slots} =
        Calculate.available_slots(ctx.in_trip, 30, @home, config.owner_timezone, [], config)

      expected =
        ctx.in_trip
        |> DateTime.new!(~T[10:00:00], @away)
        |> DateTime.shift_zone!(@home)
        |> DateTime.to_time()

      refute slots == []
      assert {:ok, first} = DateTimeUtils.parse_time_string(List.first(slots))
      assert first == expected
    end

    test "offers home hours for a date after the trip", ctx do
      config = Policy.scheduling_config(ctx.user.id, ctx.meeting_type)

      {:ok, slots} =
        Calculate.available_slots(ctx.after_trip, 30, @home, config.owner_timezone, [], config)

      refute slots == []
      assert {:ok, first} = DateTimeUtils.parse_time_string(List.first(slots))
      assert first == ~T[09:00:00]
    end
  end

  describe "agreement between the display path and the submit path" do
    test "every slot offered inside a trip is accepted by the re-check", ctx do
      config = Policy.scheduling_config(ctx.user.id, ctx.meeting_type)

      {:ok, slots} =
        Calculate.available_slots(ctx.in_trip, 30, @home, config.owner_timezone, [], config)

      refute slots == []

      Enum.each(slots, fn slot ->
        {:ok, time} = DateTimeUtils.parse_time_string(slot)
        {:ok, start_dt} = DateTime.new(ctx.in_trip, time, @home)

        assert :ok =
                 ScheduleCheck.validate_slot_on_schedule(
                   ctx.in_trip,
                   start_dt,
                   30,
                   @home,
                   config,
                   ctx.user.id
                 )
      end)
    end

    test "every slot offered after a trip is accepted by the re-check", ctx do
      config = Policy.scheduling_config(ctx.user.id, ctx.meeting_type)

      {:ok, slots} =
        Calculate.available_slots(ctx.after_trip, 30, @home, config.owner_timezone, [], config)

      Enum.each(slots, fn slot ->
        {:ok, time} = DateTimeUtils.parse_time_string(slot)
        {:ok, start_dt} = DateTime.new(ctx.after_trip, time, @home)

        assert :ok =
                 ScheduleCheck.validate_slot_on_schedule(
                   ctx.after_trip,
                   start_dt,
                   30,
                   @home,
                   config,
                   ctx.user.id
                 )
      end)
    end

    test "a home-hours slot inside the trip window is refused", ctx do
      config = Policy.scheduling_config(ctx.user.id, ctx.meeting_type)

      # 09:00 New York is 15:00 Berlin, inside 10:00-16:00, so pick a time that
      # is bookable at home but outside the trip's hours: 11:00 New York is
      # 17:00 Berlin.
      {:ok, start_dt} = DateTime.new(ctx.in_trip, ~T[11:00:00], @home)

      assert {:error, :slot_not_offered} =
               ScheduleCheck.validate_slot_on_schedule(
                 ctx.in_trip,
                 start_dt,
                 30,
                 @home,
                 config,
                 ctx.user.id
               )
    end

    test "the display path resolves the same trips as the submit path", ctx do
      display_config =
        ctx.schedule
        |> AvailabilityHelpers.schedule_config(ctx.meeting_type, nil, 30)
        |> AvailabilityHelpers.put_travel_periods(ctx.profile, ctx.in_trip, ctx.in_trip)

      expected_ids =
        ctx.profile.id
        |> Travel.for_window(ctx.in_trip, ctx.in_trip)
        |> Enum.map(& &1.id)

      assert Enum.map(display_config.travel_periods, & &1.id) == expected_ids
      refute expected_ids == []
    end

    test "the display path carries no trips for a post-return window", ctx do
      display_config =
        ctx.schedule
        |> AvailabilityHelpers.schedule_config(ctx.meeting_type, nil, 30)
        |> AvailabilityHelpers.put_travel_periods(ctx.profile, ctx.after_trip, ctx.after_trip)

      assert display_config.travel_periods == []
    end

    test "the slots the display path offers inside a trip are the slots the submit path accepts",
         ctx do
      assert_paths_agree(ctx, ctx.in_trip)
    end

    test "the slots the display path offers after a trip are the slots the submit path accepts",
         ctx do
      assert_paths_agree(ctx, ctx.after_trip)
    end
  end

  describe "the booking page's own fetch" do
    test "resolves trip hours through the slot-list call site", ctx do
      submit_config = Policy.scheduling_config(ctx.user.id, ctx.meeting_type)

      {:ok, page_slots} =
        AvailabilityHelpers.get_available_slots(
          Date.to_iso8601(ctx.in_trip),
          30,
          @home,
          ctx.user.id,
          ctx.profile,
          context(ctx)
        )

      {:ok, submit_slots} =
        Calculate.available_slots(
          ctx.in_trip,
          30,
          @home,
          submit_config.owner_timezone,
          [],
          submit_config
        )

      refute page_slots == []
      assert page_slots == submit_slots
    end

    test "resolves trip hours through the calendar-range call site", ctx do
      submit_config = Policy.scheduling_config(ctx.user.id, ctx.meeting_type)

      # The trip runs Monday to Friday but offers Wednesday alone, so the
      # Thursday inside it is bookable at home and not on the trip. The grid
      # has to agree with the submit path about that, or it greys in a day
      # nothing can be booked on.
      thursday = Date.add(ctx.in_trip, 1)

      {:ok, availability} =
        AvailabilityHelpers.get_range_availability(
          ctx.user.id,
          ctx.in_trip,
          thursday,
          @home,
          ctx.profile,
          context(ctx),
          30
        )

      {:ok, submit_thursday_slots} =
        Calculate.available_slots(
          thursday,
          30,
          @home,
          submit_config.owner_timezone,
          [],
          submit_config
        )

      assert submit_thursday_slots == []
      assert availability[Date.to_string(thursday)] == false
      assert availability[Date.to_string(ctx.in_trip)] == true
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

  # The gate assertion. Nothing here is compared against a hand-written time:
  # the slot list is computed from the *display* path's config (built the way
  # `AvailabilityHelpers` builds it, trips prefetched) and then handed to the
  # *submit* path — first as a whole, by comparing it with the list the submit
  # config yields, and then slot by slot through the re-check that guards a real
  # booking. Two paths checked against the same literal could agree with the
  # literal and still disagree with each other; these assertions can only pass
  # if the paths agree with each other.
  defp assert_paths_agree(ctx, date) do
    submit_config = Policy.scheduling_config(ctx.user.id, ctx.meeting_type)

    display_config =
      ctx.schedule
      |> AvailabilityHelpers.schedule_config(ctx.meeting_type, nil, 30)
      |> AvailabilityHelpers.put_travel_periods(ctx.profile, date, date)

    {:ok, offered} = Calculate.available_slots(date, 30, @home, @home, [], display_config)

    {:ok, from_submit_config} =
      Calculate.available_slots(date, 30, @home, submit_config.owner_timezone, [], submit_config)

    refute offered == []
    assert offered == from_submit_config

    Enum.each(offered, fn slot ->
      {:ok, time} = DateTimeUtils.parse_time_string(slot)
      {:ok, start_dt} = DateTime.new(date, time, @home)

      assert :ok =
               ScheduleCheck.validate_slot_on_schedule(
                 date,
                 start_dt,
                 30,
                 @home,
                 submit_config,
                 ctx.user.id
               )
    end)
  end
end
