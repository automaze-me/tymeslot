defmodule Tymeslot.Availability.BusinessHoursTravelTest do
  use Tymeslot.DataCase, async: true

  @moduletag :availability
  @moduletag :unit

  alias Tymeslot.Availability.BusinessHours

  @home "America/New_York"

  # 2027-03-17 is a Wednesday.
  @wednesday ~D[2027-03-17]

  defp config(overrides \\ %{}) do
    Map.merge(
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
        travel_periods: []
      },
      overrides
    )
  end

  defp berlin_trip do
    [
      %{
        start_date: ~D[2027-03-14],
        end_date: ~D[2027-03-28],
        timezone: "Europe/Berlin",
        days: [
          %{day_of_week: 3, is_available: true, start_time: ~T[10:00:00], end_time: ~T[16:00:00]}
        ]
      }
    ]
  end

  # Opens Saturday (day_of_week 6), which the default weekly schedule never
  # defines and so never marks available.
  defp berlin_saturday_trip do
    [
      %{
        start_date: ~D[2027-03-14],
        end_date: ~D[2027-03-28],
        timezone: "Europe/Berlin",
        days: [
          %{day_of_week: 6, is_available: true, start_time: ~T[10:00:00], end_time: ~T[14:00:00]}
        ]
      }
    ]
  end

  # Defines no days at all — every date it covers is a travel day, closed
  # regardless of what the home weekly schedule says.
  defp travel_day_off_trip do
    [
      %{
        start_date: ~D[2027-03-14],
        end_date: ~D[2027-03-28],
        timezone: "Europe/Berlin",
        days: []
      }
    ]
  end

  # The one window `owner_windows/4` resolves for `date`, or nil when it
  # offers none.
  defp window_on(date, schedule_id, config) do
    case BusinessHours.owner_windows([date], schedule_id, @home, config) do
      [window] -> window
      [] -> nil
    end
  end

  defp local_time(instant, zone), do: instant |> DateTime.shift_zone!(zone) |> DateTime.to_time()

  describe "owner_windows/4" do
    test "uses the home zone and schedule hours with no trips" do
      window = window_on(@wednesday, 1, config())

      assert window.start_dt == DateTime.new!(@wednesday, ~T[09:00:00], @home)
    end

    test "uses the trip zone and trip hours inside a trip" do
      window = window_on(@wednesday, 1, config(%{travel_periods: berlin_trip()}))

      # 10:00 to 16:00 read on the Berlin clock.
      assert local_time(window.start_dt, "Europe/Berlin") == ~T[10:00:00]
      assert local_time(window.end_dt, "Europe/Berlin") == ~T[16:00:00]
    end

    test "a trip's hours are the same instants whichever zone reads them" do
      window = window_on(@wednesday, 1, config(%{travel_periods: berlin_trip()}))

      expected =
        @wednesday
        |> DateTime.new!(~T[10:00:00], "Europe/Berlin")
        |> DateTime.shift_zone!(@home)
        |> DateTime.to_time()

      assert local_time(window.start_dt, @home) == expected
    end

    test "leaves a weekday the trip does not define unbookable" do
      config = config(%{travel_periods: berlin_trip()})
      # 2027-03-18 is a Thursday, undefined by the trip but available on the schedule.
      thursday = ~D[2027-03-18]

      schedule_config =
        Map.put(config, :weekly_schedule, [
          %{
            day_of_week: 4,
            is_available: true,
            start_time: ~T[09:00:00],
            end_time: ~T[17:00:00],
            breaks: []
          }
        ])

      assert window_on(thursday, 1, schedule_config) == nil
    end

    test "an unavailable override still wins inside a trip" do
      config =
        config(%{
          travel_periods: berlin_trip(),
          overrides: [%{date: @wednesday, schedule_id: 1, override_type: "unavailable"}]
        })

      assert window_on(@wednesday, 1, config) == nil
    end

    test "a custom-hours override inside a trip is read in the trip zone" do
      config =
        config(%{
          travel_periods: berlin_trip(),
          overrides: [
            %{
              date: @wednesday,
              schedule_id: 1,
              override_type: "custom_hours",
              start_time: ~T[13:00:00],
              end_time: ~T[15:00:00]
            }
          ]
        })

      window = window_on(@wednesday, 1, config)

      assert local_time(window.start_dt, "Europe/Berlin") == ~T[13:00:00]
    end

    test "a trip applies even when no schedule resolves" do
      window = window_on(@wednesday, nil, config(%{travel_periods: berlin_trip()}))

      assert local_time(window.start_dt, "Europe/Berlin") == ~T[10:00:00]
    end

    test "uses the home zone and schedule hours for a date outside every trip" do
      # 2027-03-31 is a Wednesday, past berlin_trip's 2027-03-28 end_date.
      past_the_trip = ~D[2027-03-31]
      window = window_on(past_the_trip, 1, config(%{travel_periods: berlin_trip()}))

      assert window.start_dt == DateTime.new!(past_the_trip, ~T[09:00:00], @home)
    end

    test "the home pattern's breaks do not follow the owner onto a trip" do
      lunch = %{start_time: ~T[12:00:00], end_time: ~T[13:00:00]}

      config =
        config(%{
          travel_periods: berlin_trip(),
          weekly_schedule: [
            %{
              day_of_week: 3,
              is_available: true,
              start_time: ~T[09:00:00],
              end_time: ~T[17:00:00],
              breaks: [lunch]
            }
          ]
        })

      assert window_on(@wednesday, 1, config).breaks == []
      assert [_lunch] = window_on(~D[2027-03-31], 1, config).breaks
    end
  end

  describe "time_off_intervals/4" do
    test "a day off during a trip closes that day on the trip's clock" do
      config =
        config(%{
          travel_periods: berlin_trip(),
          time_off: [
            %{starts_on: @wednesday, ends_on: @wednesday, start_time: nil, end_time: nil}
          ]
        })

      assert [{from, to}] =
               BusinessHours.time_off_intervals(
                 Date.range(@wednesday, @wednesday),
                 1,
                 @home,
                 config
               )

      assert from == @wednesday |> DateTime.new!(~T[00:00:00], "Europe/Berlin") |> utc()
      assert to == ~D[2027-03-18] |> DateTime.new!(~T[00:00:00], "Europe/Berlin") |> utc()
    end

    test "a day off outside every trip stays on the home clock" do
      past_the_trip = ~D[2027-03-31]

      config =
        config(%{
          travel_periods: berlin_trip(),
          time_off: [
            %{starts_on: past_the_trip, ends_on: past_the_trip, start_time: nil, end_time: nil}
          ]
        })

      assert [{from, _to}] =
               BusinessHours.time_off_intervals(
                 Date.range(past_the_trip, past_the_trip),
                 1,
                 @home,
                 config
               )

      assert from == past_the_trip |> DateTime.new!(~T[00:00:00], @home) |> utc()
    end
  end

  defp utc(datetime), do: DateTime.shift_zone!(datetime, "Etc/UTC")

  describe "business_day?/3" do
    test "a trip opens a weekday the home schedule marks unavailable" do
      config = config(%{travel_periods: berlin_saturday_trip()})
      # 2027-03-20 is a Saturday, inside the trip and outside the Mon-Fri fallback.
      saturday = ~D[2027-03-20]

      assert BusinessHours.business_day?(saturday, 1, config)
    end

    test "a trip opens a weekday even when no schedule resolves" do
      config = config(%{travel_periods: berlin_saturday_trip()})
      saturday = ~D[2027-03-20]

      assert BusinessHours.business_day?(saturday, nil, config)
    end

    test "a trip closes a weekday the home schedule marks available" do
      config = config(%{travel_periods: travel_day_off_trip()})

      refute BusinessHours.business_day?(@wednesday, 1, config)
    end

    test "an unavailable override still wins business_day?/3 inside a trip" do
      config =
        config(%{
          travel_periods: berlin_trip(),
          overrides: [%{date: @wednesday, schedule_id: 1, override_type: "unavailable"}]
        })

      refute BusinessHours.business_day?(@wednesday, 1, config)
    end

    test "answers the same outside every trip as with no trips at all" do
      # 2027-03-31 is a Wednesday, past berlin_trip's 2027-03-28 end_date.
      past_the_trip = ~D[2027-03-31]
      no_trips = config()
      with_a_trip = config(%{travel_periods: berlin_trip()})

      assert BusinessHours.business_day?(past_the_trip, 1, no_trips) ==
               BusinessHours.business_day?(past_the_trip, 1, with_a_trip)
    end
  end
end
