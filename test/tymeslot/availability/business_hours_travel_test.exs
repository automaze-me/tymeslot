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

  describe "get_business_hours_in_timezone/5" do
    test "uses the home zone and schedule hours with no trips" do
      assert {:ok, hours} =
               BusinessHours.get_business_hours_in_timezone(@wednesday, 1, @home, @home, config())

      assert DateTime.to_time(hours.start_datetime) == ~T[09:00:00]
      assert hours.start_datetime.time_zone == @home
    end

    test "uses the trip zone and trip hours inside a trip" do
      config = config(%{travel_periods: berlin_trip()})

      assert {:ok, hours} =
               BusinessHours.get_business_hours_in_timezone(
                 @wednesday,
                 1,
                 @home,
                 "Europe/Berlin",
                 config
               )

      # 10:00 read in Berlin, rendered in Berlin.
      assert DateTime.to_time(hours.start_datetime) == ~T[10:00:00]
      assert DateTime.to_time(hours.end_datetime) == ~T[16:00:00]
    end

    test "converts trip hours into the booker's zone" do
      config = config(%{travel_periods: berlin_trip()})

      assert {:ok, hours} =
               BusinessHours.get_business_hours_in_timezone(@wednesday, 1, @home, @home, config)

      expected =
        @wednesday
        |> DateTime.new!(~T[10:00:00], "Europe/Berlin")
        |> DateTime.shift_zone!(@home)
        |> DateTime.to_time()

      assert DateTime.to_time(hours.start_datetime) == expected
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

      assert {:ok, hours} =
               BusinessHours.get_business_hours_in_timezone(
                 thursday,
                 1,
                 @home,
                 @home,
                 schedule_config
               )

      assert hours.start_datetime == nil
    end

    test "an unavailable override still wins inside a trip" do
      config =
        config(%{
          travel_periods: berlin_trip(),
          overrides: [%{date: @wednesday, schedule_id: 1, override_type: "unavailable"}]
        })

      assert {:ok, hours} =
               BusinessHours.get_business_hours_in_timezone(@wednesday, 1, @home, @home, config)

      assert hours.start_datetime == nil
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

      assert {:ok, hours} =
               BusinessHours.get_business_hours_in_timezone(
                 @wednesday,
                 1,
                 @home,
                 "Europe/Berlin",
                 config
               )

      assert DateTime.to_time(hours.start_datetime) == ~T[13:00:00]
    end

    test "a trip applies even when no schedule resolves" do
      config = config(%{travel_periods: berlin_trip()})

      assert {:ok, hours} =
               BusinessHours.get_business_hours_in_timezone(
                 @wednesday,
                 nil,
                 @home,
                 "Europe/Berlin",
                 config
               )

      assert DateTime.to_time(hours.start_datetime) == ~T[10:00:00]
    end
  end
end
