defmodule Tymeslot.Availability.TravelPeriodQueriesTest do
  use Tymeslot.DataCase, async: true

  @moduletag :availability
  @moduletag :queries

  import Tymeslot.Factory

  alias Tymeslot.Availability.TravelPeriodQueries

  describe "list_overlapping/3" do
    test "returns a trip that overlaps the window and preloads its days" do
      profile = insert(:profile)

      period =
        insert(:travel_period,
          profile: profile,
          start_date: ~D[2027-03-14],
          end_date: ~D[2027-03-28]
        )

      insert(:travel_period_day, travel_period: period, day_of_week: 3)

      assert [found] =
               TravelPeriodQueries.list_overlapping(profile.id, ~D[2027-03-01], ~D[2027-03-31])

      assert found.id == period.id
      assert [day] = found.days
      assert day.day_of_week == 3
    end

    test "includes a trip that only partially overlaps at each edge" do
      profile = insert(:profile)

      insert(:travel_period,
        profile: profile,
        start_date: ~D[2027-02-25],
        end_date: ~D[2027-03-02],
        label: "straddles the start"
      )

      insert(:travel_period,
        profile: profile,
        start_date: ~D[2027-03-30],
        end_date: ~D[2027-04-04],
        label: "straddles the end"
      )

      found = TravelPeriodQueries.list_overlapping(profile.id, ~D[2027-03-01], ~D[2027-03-31])

      assert length(found) == 2
    end

    test "excludes a trip entirely outside the window" do
      profile = insert(:profile)

      insert(:travel_period,
        profile: profile,
        start_date: ~D[2027-05-01],
        end_date: ~D[2027-05-10]
      )

      assert [] =
               TravelPeriodQueries.list_overlapping(profile.id, ~D[2027-03-01], ~D[2027-03-31])
    end

    test "excludes another profile's trip" do
      profile = insert(:profile)
      other = insert(:profile)

      insert(:travel_period,
        profile: other,
        start_date: ~D[2027-03-14],
        end_date: ~D[2027-03-28]
      )

      assert [] =
               TravelPeriodQueries.list_overlapping(profile.id, ~D[2027-03-01], ~D[2027-03-31])
    end
  end

  describe "overlapping/4" do
    test "finds a colliding trip" do
      profile = insert(:profile)

      insert(:travel_period,
        profile: profile,
        start_date: ~D[2027-03-14],
        end_date: ~D[2027-03-28]
      )

      assert [_collision] =
               TravelPeriodQueries.overlapping(profile.id, ~D[2027-03-20], ~D[2027-04-02], nil)
    end

    test "treats touching dates as overlapping, since both ends are inclusive" do
      profile = insert(:profile)

      insert(:travel_period,
        profile: profile,
        start_date: ~D[2027-03-14],
        end_date: ~D[2027-03-28]
      )

      assert [_collision] =
               TravelPeriodQueries.overlapping(profile.id, ~D[2027-03-28], ~D[2027-04-02], nil)
    end

    test "excludes the trip being edited" do
      profile = insert(:profile)

      period =
        insert(:travel_period,
          profile: profile,
          start_date: ~D[2027-03-14],
          end_date: ~D[2027-03-28]
        )

      assert [] =
               TravelPeriodQueries.overlapping(
                 profile.id,
                 ~D[2027-03-15],
                 ~D[2027-03-29],
                 period.id
               )
    end
  end
end
