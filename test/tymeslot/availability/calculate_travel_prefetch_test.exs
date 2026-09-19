defmodule Tymeslot.Availability.CalculateTravelPrefetchTest do
  use Tymeslot.DataCase, async: true

  @moduletag :availability
  @moduletag :unit

  import Tymeslot.Factory

  alias Tymeslot.Availability.Calculate

  describe "prefetch_travel_periods/4" do
    test "loads the window's trips with days preloaded" do
      profile = insert(:profile)

      period =
        insert(:travel_period,
          profile: profile,
          start_date: ~D[2027-03-14],
          end_date: ~D[2027-03-28]
        )

      insert(:travel_period_day, travel_period: period, day_of_week: 3)

      config = Calculate.prefetch_travel_periods(%{}, profile.id, ~D[2027-03-01], ~D[2027-03-31])

      assert [loaded] = config.travel_periods
      assert loaded.id == period.id
      assert [_day] = loaded.days
    end

    test "passes the config through untouched when there is no profile" do
      config = Calculate.prefetch_travel_periods(%{}, nil, ~D[2027-03-01], ~D[2027-03-31])

      refute Map.has_key?(config, :travel_periods)
    end

    test "leaves an already-populated key alone" do
      profile = insert(:profile)

      insert(:travel_period,
        profile: profile,
        start_date: ~D[2027-03-14],
        end_date: ~D[2027-03-28]
      )

      config =
        Calculate.prefetch_travel_periods(
          %{travel_periods: []},
          profile.id,
          ~D[2027-03-01],
          ~D[2027-03-31]
        )

      assert config.travel_periods == []
    end
  end
end
