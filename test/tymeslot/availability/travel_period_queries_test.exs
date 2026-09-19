defmodule Tymeslot.Availability.TravelPeriodQueriesTest do
  use Tymeslot.DataCase, async: true

  @moduletag :availability
  @moduletag :queries

  import Tymeslot.Factory

  alias Tymeslot.Availability.TravelPeriodDaySchema
  alias Tymeslot.Availability.TravelPeriodQueries
  alias Tymeslot.Availability.TravelPeriodSchema

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

    test "includes a trip that only partially overlaps at each edge, ordered by start_date" do
      profile = insert(:profile)

      # Inserted end-first, so a passing order assertion cannot be an accident
      # of insertion order.
      straddles_end =
        insert(:travel_period,
          profile: profile,
          start_date: ~D[2027-03-30],
          end_date: ~D[2027-04-04],
          label: "straddles the end"
        )

      straddles_start =
        insert(:travel_period,
          profile: profile,
          start_date: ~D[2027-02-25],
          end_date: ~D[2027-03-02],
          label: "straddles the start"
        )

      found = TravelPeriodQueries.list_overlapping(profile.id, ~D[2027-03-01], ~D[2027-03-31])

      assert Enum.map(found, & &1.id) == [straddles_start.id, straddles_end.id]
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

  describe "list_by_profile/1" do
    test "returns a profile's trips ordered by start_date and excludes another profile's" do
      profile = insert(:profile)
      other = insert(:profile)

      # Inserted latest-first, so a passing order assertion cannot be an
      # accident of insertion order.
      later =
        insert(:travel_period,
          profile: profile,
          start_date: ~D[2027-06-01],
          end_date: ~D[2027-06-10],
          label: "later trip"
        )

      earlier =
        insert(:travel_period,
          profile: profile,
          start_date: ~D[2027-01-01],
          end_date: ~D[2027-01-10],
          label: "earlier trip"
        )

      insert(:travel_period,
        profile: other,
        start_date: ~D[2027-02-01],
        end_date: ~D[2027-02-10]
      )

      found = TravelPeriodQueries.list_by_profile(profile.id)

      assert Enum.map(found, & &1.id) == [earlier.id, later.id]
    end

    test "preloads :days" do
      profile = insert(:profile)
      period = insert(:travel_period, profile: profile)
      insert(:travel_period_day, travel_period: period, day_of_week: 5)

      assert [found] = TravelPeriodQueries.list_by_profile(profile.id)
      assert [day] = found.days
      assert day.day_of_week == 5
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

  describe "insert_period/1" do
    test "inserts a trip from a valid changeset and it is readable back" do
      profile = insert(:profile)

      attrs = %{
        profile_id: profile.id,
        label: "Conference trip",
        start_date: ~D[2027-07-01],
        end_date: ~D[2027-07-10],
        timezone: "Europe/Berlin"
      }

      changeset = TravelPeriodSchema.changeset(%TravelPeriodSchema{}, attrs)

      assert {:ok, period} = TravelPeriodQueries.insert_period(changeset)

      reloaded = Repo.get(TravelPeriodSchema, period.id)
      assert reloaded.label == "Conference trip"
      assert reloaded.start_date == ~D[2027-07-01]
      assert reloaded.end_date == ~D[2027-07-10]
    end

    test "returns an error changeset for an invalid trip and inserts nothing" do
      profile = insert(:profile)

      attrs = %{
        profile_id: profile.id,
        label: "Backwards trip",
        # end_date before start_date
        start_date: ~D[2027-07-10],
        end_date: ~D[2027-07-01],
        timezone: "Europe/Berlin"
      }

      changeset = TravelPeriodSchema.changeset(%TravelPeriodSchema{}, attrs)

      assert {:error, error_changeset} = TravelPeriodQueries.insert_period(changeset)
      refute error_changeset.valid?
      assert "must be on or after the start date" in errors_on(error_changeset)[:end_date]
      assert TravelPeriodQueries.list_by_profile(profile.id) == []
    end
  end

  describe "update_period/1" do
    test "updates a trip and the change is readable back" do
      period = insert(:travel_period, label: "Old label")

      changeset = TravelPeriodSchema.changeset(period, %{label: "New label"})

      assert {:ok, updated} = TravelPeriodQueries.update_period(changeset)
      assert updated.label == "New label"

      reloaded = Repo.get(TravelPeriodSchema, period.id)
      assert reloaded.label == "New label"
    end
  end

  describe "delete_period/1" do
    test "deletes a trip and its days cascade with it" do
      period = insert(:travel_period)
      insert(:travel_period_day, travel_period: period, day_of_week: 2)

      assert {:ok, _deleted} = TravelPeriodQueries.delete_period(period)

      assert Repo.get(TravelPeriodSchema, period.id) == nil

      remaining_days =
        Repo.all(where(TravelPeriodDaySchema, [d], d.travel_period_id == ^period.id))

      assert remaining_days == []
    end
  end

  describe "upsert_day/1" do
    test "round-trips: a second call for the same pair replaces the row rather than duplicating it" do
      period = insert(:travel_period)

      assert {:ok, first} =
               TravelPeriodQueries.upsert_day(%{
                 travel_period_id: period.id,
                 day_of_week: 3,
                 is_available: true,
                 start_time: ~T[09:00:00],
                 end_time: ~T[12:00:00]
               })

      assert first.is_available == true
      assert first.start_time == ~T[09:00:00]
      assert first.end_time == ~T[12:00:00]

      assert {:ok, second} =
               TravelPeriodQueries.upsert_day(%{
                 travel_period_id: period.id,
                 day_of_week: 3,
                 is_available: false,
                 start_time: nil,
                 end_time: nil
               })

      assert second.is_available == false
      assert second.start_time == nil
      assert second.end_time == nil

      rows = Repo.all(where(TravelPeriodDaySchema, [d], d.travel_period_id == ^period.id))
      assert length(rows) == 1

      [stored] = rows
      assert stored.is_available == false
      assert stored.start_time == nil
      assert stored.end_time == nil
    end
  end
end
