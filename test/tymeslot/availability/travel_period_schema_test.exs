defmodule Tymeslot.Availability.TravelPeriodSchemaTest do
  use Tymeslot.DataCase, async: true

  @moduletag :availability
  @moduletag :schema

  import Tymeslot.Factory

  alias Tymeslot.Availability.TravelPeriodDaySchema
  alias Tymeslot.Availability.TravelPeriodSchema

  describe "changeset/2" do
    test "accepts a valid trip" do
      profile = insert(:profile)

      changeset =
        TravelPeriodSchema.changeset(%TravelPeriodSchema{}, %{
          profile_id: profile.id,
          label: "Berlin, spring",
          start_date: ~D[2027-03-14],
          end_date: ~D[2027-03-28],
          timezone: "Europe/Berlin"
        })

      assert changeset.valid?
      assert {:ok, period} = Repo.insert(changeset)
      assert period.timezone == "Europe/Berlin"
    end

    test "rejects an unknown timezone" do
      profile = insert(:profile)

      changeset =
        TravelPeriodSchema.changeset(%TravelPeriodSchema{}, %{
          profile_id: profile.id,
          label: "Nowhere",
          start_date: ~D[2027-03-14],
          end_date: ~D[2027-03-28],
          timezone: "Mars/Olympus_Mons"
        })

      refute changeset.valid?
      assert "is not a valid timezone" in errors_on(changeset).timezone
    end

    test "rejects an end date before the start date" do
      profile = insert(:profile)

      changeset =
        TravelPeriodSchema.changeset(%TravelPeriodSchema{}, %{
          profile_id: profile.id,
          label: "Backwards",
          start_date: ~D[2027-03-28],
          end_date: ~D[2027-03-14],
          timezone: "Europe/Berlin"
        })

      refute changeset.valid?
      assert "must be on or after the start date" in errors_on(changeset).end_date
    end

    test "accepts a single-day trip" do
      profile = insert(:profile)

      changeset =
        TravelPeriodSchema.changeset(%TravelPeriodSchema{}, %{
          profile_id: profile.id,
          label: "Day trip",
          start_date: ~D[2027-03-14],
          end_date: ~D[2027-03-14],
          timezone: "Europe/Berlin"
        })

      assert changeset.valid?
    end
  end

  describe "TravelPeriodDaySchema.changeset/2" do
    test "requires hours when the day is available" do
      period = insert(:travel_period)

      changeset =
        TravelPeriodDaySchema.changeset(%TravelPeriodDaySchema{}, %{
          travel_period_id: period.id,
          day_of_week: 3,
          is_available: true
        })

      refute changeset.valid?
      assert "are required when day is available" in errors_on(changeset).start_time
    end

    test "rejects an end time at or before the start time" do
      period = insert(:travel_period)

      changeset =
        TravelPeriodDaySchema.changeset(%TravelPeriodDaySchema{}, %{
          travel_period_id: period.id,
          day_of_week: 3,
          is_available: true,
          start_time: ~T[16:00:00],
          end_time: ~T[10:00:00]
        })

      refute changeset.valid?
    end

    test "rejects a day_of_week outside 1..7" do
      period = insert(:travel_period)

      changeset =
        TravelPeriodDaySchema.changeset(%TravelPeriodDaySchema{}, %{
          travel_period_id: period.id,
          day_of_week: 8,
          is_available: false
        })

      refute changeset.valid?
    end

    test "accepts one day per weekday but not two" do
      period = insert(:travel_period)

      attrs = %{
        travel_period_id: period.id,
        day_of_week: 3,
        is_available: true,
        start_time: ~T[10:00:00],
        end_time: ~T[16:00:00]
      }

      assert {:ok, _day} =
               Repo.insert(TravelPeriodDaySchema.changeset(%TravelPeriodDaySchema{}, attrs))

      assert {:error, changeset} =
               Repo.insert(TravelPeriodDaySchema.changeset(%TravelPeriodDaySchema{}, attrs))

      assert "has already been taken" in errors_on(changeset).travel_period_id
    end
  end
end
