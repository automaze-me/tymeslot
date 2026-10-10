defmodule Tymeslot.Availability.SlotGridTravelTest do
  use ExUnit.Case, async: true

  @moduletag :availability
  @moduletag :unit

  alias Tymeslot.Availability.SlotGrid

  # UTC-11 at home and UTC+14 on the trip, 25 hours apart: the trip's clock is
  # already two dates ahead of a home-zone booker's late evening.
  @home "Pacific/Pago_Pago"
  @away "Pacific/Kiritimati"

  # 2027-03-18 is a Thursday; the trip opens only on Saturday 2027-03-20, for
  # the first two hours after its midnight.
  @thursday ~D[2027-03-18]

  defp config do
    %{
      schedule_id: 1,
      weekly_schedule: [],
      overrides: [],
      time_off: [],
      travel_periods: [
        %{
          start_date: ~D[2027-03-14],
          end_date: ~D[2027-03-28],
          timezone: @away,
          days: [
            %{
              day_of_week: 6,
              is_available: true,
              start_time: ~T[00:00:00],
              end_time: ~T[02:00:00]
            }
          ]
        }
      ]
    }
  end

  test "reads the trip zone's dates as well as the home zone's around a booker's day" do
    # Saturday 00:00 in Kiritimati is Thursday 23:00 in Pago Pago. The home
    # zone's dates around Thursday stop at Friday, so reading only those never
    # reaches the trip's Saturday and the evening would offer nothing.
    assert {:ok, starts} = SlotGrid.starts_for_date(@thursday, 30, @home, @home, config())

    assert starts == [
             DateTime.new!(@thursday, ~T[23:00:00], @home),
             DateTime.new!(@thursday, ~T[23:30:00], @home)
           ]

    assert DateTime.compare(hd(starts), DateTime.new!(~D[2027-03-20], ~T[00:00:00], @away)) ==
             :eq
  end
end
