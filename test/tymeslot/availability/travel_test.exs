defmodule Tymeslot.Availability.TravelTest do
  use Tymeslot.DataCase, async: true

  @moduletag :availability
  @moduletag :unit

  import Tymeslot.Factory

  alias Tymeslot.Availability.Travel

  describe "create_period/2" do
    test "creates a trip" do
      profile = insert(:profile)

      assert {:ok, period} =
               Travel.create_period(profile, %{
                 label: "Berlin, spring",
                 start_date: ~D[2027-03-14],
                 end_date: ~D[2027-03-28],
                 timezone: "Europe/Berlin"
               })

      assert period.profile_id == profile.id
      assert period.timezone == "Europe/Berlin"
    end

    test "refuses a trip overlapping an existing one" do
      profile = insert(:profile)

      insert(:travel_period,
        profile: profile,
        start_date: ~D[2027-03-14],
        end_date: ~D[2027-03-28]
      )

      assert {:error, changeset} =
               Travel.create_period(profile, %{
                 label: "Overlaps",
                 start_date: ~D[2027-03-20],
                 end_date: ~D[2027-04-02],
                 timezone: "Europe/Paris"
               })

      assert "overlaps an existing trip" in errors_on(changeset).start_date
    end

    test "allows a trip abutting an existing one without overlapping" do
      profile = insert(:profile)

      insert(:travel_period,
        profile: profile,
        start_date: ~D[2027-03-14],
        end_date: ~D[2027-03-28]
      )

      assert {:ok, _period} =
               Travel.create_period(profile, %{
                 label: "The day after",
                 start_date: ~D[2027-03-29],
                 end_date: ~D[2027-04-02],
                 timezone: "Europe/Paris"
               })
    end

    test "ignores another profile's trips when checking overlap" do
      profile = insert(:profile)
      other = insert(:profile)

      insert(:travel_period,
        profile: other,
        start_date: ~D[2027-03-14],
        end_date: ~D[2027-03-28]
      )

      assert {:ok, _period} =
               Travel.create_period(profile, %{
                 label: "Same dates, different person",
                 start_date: ~D[2027-03-14],
                 end_date: ~D[2027-03-28],
                 timezone: "Europe/Berlin"
               })
    end
  end

  describe "update_period/3" do
    test "does not treat the trip being edited as an overlap with itself" do
      profile = insert(:profile)

      period =
        insert(:travel_period,
          profile: profile,
          start_date: ~D[2027-03-14],
          end_date: ~D[2027-03-28]
        )

      assert {:ok, updated} =
               Travel.update_period(profile, period, %{end_date: ~D[2027-03-30]})

      assert updated.end_date == ~D[2027-03-30]
    end

    test "refuses a trip belonging to another profile" do
      profile = insert(:profile)
      other = insert(:profile)

      period =
        insert(:travel_period,
          profile: other,
          start_date: ~D[2027-03-14],
          end_date: ~D[2027-03-28]
        )

      assert {:error, changeset} =
               Travel.update_period(profile, period, %{end_date: ~D[2027-03-30]})

      assert "does not belong to this profile" in errors_on(changeset).base

      unchanged = List.first(Travel.for_window(other.id, ~D[2027-03-14], ~D[2027-03-14]))
      assert unchanged.end_date == ~D[2027-03-28]
    end
  end

  describe "normalise/1 (via create_period/2)" do
    test "accepts string keys and drops unknown ones instead of raising" do
      profile = insert(:profile)

      # Shaped like a `phx-change` payload: real fields as strings, plus a
      # LiveView `_unused_*` key that is not an existing atom.
      assert {:ok, period} =
               Travel.create_period(profile, %{
                 "label" => "Berlin, spring",
                 "start_date" => "2027-03-14",
                 "end_date" => "2027-03-28",
                 "timezone" => "Europe/Berlin",
                 "_unused_label" => "whatever the browser sent"
               })

      assert period.label == "Berlin, spring"
      assert period.timezone == "Europe/Berlin"
    end
  end

  describe "for_window/3" do
    test "returns trips overlapping the window with days preloaded" do
      profile = insert(:profile)

      period =
        insert(:travel_period,
          profile: profile,
          start_date: ~D[2027-03-14],
          end_date: ~D[2027-03-28]
        )

      insert(:travel_period_day, travel_period: period, day_of_week: 3)

      assert [found] = Travel.for_window(profile.id, ~D[2027-03-01], ~D[2027-03-31])
      assert [_day] = found.days
    end
  end

  describe "set_day/3" do
    test "replaces the hours for a weekday already set" do
      profile = insert(:profile)
      period = insert(:travel_period, profile: profile)

      assert {:ok, _first} =
               Travel.set_day(profile, period, %{
                 day_of_week: 3,
                 is_available: true,
                 start_time: ~T[10:00:00],
                 end_time: ~T[16:00:00]
               })

      assert {:ok, replaced} =
               Travel.set_day(profile, period, %{
                 day_of_week: 3,
                 is_available: true,
                 start_time: ~T[11:00:00],
                 end_time: ~T[15:00:00]
               })

      assert replaced.start_time == ~T[11:00:00]
    end
  end
end
