defmodule Tymeslot.Availability.TravelDstAndPolicyTest do
  use Tymeslot.DataCase, async: true

  @moduletag :availability
  @moduletag :integration

  import Tymeslot.Factory

  alias Tymeslot.Availability.BusinessHours
  alias Tymeslot.Availability.Calculate
  alias Tymeslot.Availability.Travel
  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Utils.DateTimeUtils

  @home "America/New_York"
  @away "Europe/Berlin"

  describe "a trip straddling a DST boundary" do
    # The EU moves to summer time on the last Sunday of March: 2027-03-28.
    # These dates are fixed deliberately — a DST test cannot use relative dates,
    # and nothing here depends on today, so the test does not rot.
    @before_switch ~D[2027-03-24]
    @after_switch ~D[2027-03-31]

    defp straddling_trip do
      [
        %{
          start_date: ~D[2027-03-22],
          end_date: ~D[2027-04-04],
          timezone: @away,
          days: [
            %{
              day_of_week: 3,
              is_available: true,
              start_time: ~T[10:00:00],
              end_time: ~T[16:00:00]
            }
          ]
        }
      ]
    end

    defp config do
      %{
        weekly_schedule: [
          %{
            day_of_week: 3,
            is_available: true,
            start_time: ~T[09:00:00],
            end_time: ~T[17:00:00],
            breaks: []
          }
        ],
        overrides: [],
        travel_periods: straddling_trip()
      }
    end

    test "reads 10:00 local on both sides of the switch" do
      for date <- [@before_switch, @after_switch] do
        assert {:ok, hours} =
                 BusinessHours.get_business_hours_in_timezone(date, 1, @home, @away, config())

        assert DateTime.to_time(hours.start_datetime) == ~T[10:00:00],
               "expected 10:00 Berlin local on #{date}"
      end
    end

    test "those two 10:00s are different instants, an hour apart in UTC" do
      instants =
        for date <- [@before_switch, @after_switch] do
          {:ok, hours} =
            BusinessHours.get_business_hours_in_timezone(date, 1, @home, "Etc/UTC", config())

          DateTime.to_time(hours.start_datetime)
        end

      # 10:00 CET is 09:00 UTC; 10:00 CEST is 08:00 UTC. Were the zone resolved
      # once and applied as a fixed offset, these would be equal.
      assert instants == [~T[09:00:00], ~T[08:00:00]]
    end
  end

  describe "scheduling policy during a trip" do
    defp policy_setup(advance_booking_days) do
      user = insert(:user)
      profile = insert(:profile, user: user, timezone: @home)

      schedule =
        insert(:availability_schedule,
          profile: profile,
          is_default: true,
          buffer_minutes: 0,
          min_advance_hours: 0,
          advance_booking_days: advance_booking_days
        )

      # Closed at home on the trip's weekday: the trip must be the only thing
      # that can open it. If both the home schedule and the trip offered
      # Wednesday hours, a broken `OwnerFrame` that fell back to the home
      # schedule would still produce slots and this fixture could never catch
      # it — see the mutation evidence in the fix report for task 7b.
      insert(:weekly_availability,
        schedule: schedule,
        day_of_week: 3,
        is_available: false
      )

      meeting_type =
        insert(:meeting_type,
          user: user,
          duration_minutes: 30,
          availability_schedule_id: schedule.id
        )

      base = Date.add(Date.utc_today(), 60)
      wednesday = Date.add(base, rem(10 - Date.day_of_week(base), 7))

      {:ok, trip} =
        Travel.create_period(profile, %{
          label: "Berlin",
          start_date: Date.add(wednesday, -2),
          end_date: Date.add(wednesday, 2),
          timezone: @away
        })

      {:ok, _day} =
        Travel.set_day(profile, trip, %{
          day_of_week: 3,
          is_available: true,
          start_time: ~T[10:00:00],
          end_time: ~T[16:00:00]
        })

      %{user: user, meeting_type: meeting_type, wednesday: wednesday}
    end

    test "the schedule's booking horizon still gates a trip date" do
      %{user: user, meeting_type: meeting_type, wednesday: wednesday} = policy_setup(10)

      config = Policy.scheduling_config(user.id, meeting_type)

      # All three policy values come from the schedule, never from the trip —
      # `TravelPeriodSchema` has no fields for any of them.
      assert config.buffer_minutes == 0
      assert config.min_advance_hours == 0
      assert config.max_advance_booking_days == 10

      # The trip date is 60-plus days out, well beyond a 10-day horizon. The
      # home schedule is closed on this weekday (see policy_setup/1), so a
      # non-empty result here could only come from the trip's own hours —
      # this proves the horizon gates a trip date even though the trip itself
      # would otherwise open it.
      assert {:ok, []} =
               Calculate.available_slots(wednesday, 30, @home, config.owner_timezone, [], config)
    end

    test "the same trip date is offered once the horizon allows it, at the trip's hours" do
      %{user: user, meeting_type: meeting_type, wednesday: wednesday} = policy_setup(365)

      config = Policy.scheduling_config(user.id, meeting_type)

      assert config.buffer_minutes == 0
      assert config.min_advance_hours == 0
      assert config.max_advance_booking_days == 365

      assert {:ok, slots} =
               Calculate.available_slots(wednesday, 30, @home, config.owner_timezone, [], config)

      # The home schedule is closed on this weekday, so any slot at all proves
      # the trip supplied it — and the exact time proves it came from the
      # trip's 10:00 Berlin hours, not some other source.
      expected =
        wednesday
        |> DateTime.new!(~T[10:00:00], @away)
        |> DateTime.shift_zone!(@home)
        |> DateTime.to_time()

      refute slots == []
      assert {:ok, first} = DateTimeUtils.parse_time_string(List.first(slots))
      assert first == expected
    end
  end
end
