defmodule Tymeslot.Availability.TravelTimezoneOnTest do
  use Tymeslot.DataCase, async: true

  @moduletag :availability
  @moduletag :unit

  import Tymeslot.Factory

  alias Tymeslot.Availability.Travel
  alias Tymeslot.Profiles

  describe "timezone_on/2" do
    test "returns the trip zone for a date inside a trip" do
      profile = insert(:profile, timezone: "America/New_York")

      insert(:travel_period,
        profile: profile,
        start_date: ~D[2027-03-14],
        end_date: ~D[2027-03-28],
        timezone: "Europe/Berlin"
      )

      assert Travel.timezone_on(profile, ~D[2027-03-17]) == "Europe/Berlin"
    end

    test "returns the profile zone outside every trip" do
      profile = insert(:profile, timezone: "America/New_York")

      insert(:travel_period,
        profile: profile,
        start_date: ~D[2027-03-14],
        end_date: ~D[2027-03-28],
        timezone: "Europe/Berlin"
      )

      assert Travel.timezone_on(profile, ~D[2027-04-07]) == "America/New_York"
    end

    test "falls back to the default when the profile has no zone" do
      profile = insert(:profile, timezone: nil)

      assert Travel.timezone_on(profile, ~D[2027-03-17]) == Profiles.get_default_timezone()
    end
  end

  describe "timezone_for_user_on/2" do
    test "resolves through the user's profile" do
      user = insert(:user)
      profile = insert(:profile, user: user, timezone: "America/New_York")

      insert(:travel_period,
        profile: profile,
        start_date: ~D[2027-03-14],
        end_date: ~D[2027-03-28],
        timezone: "Europe/Berlin"
      )

      assert Travel.timezone_for_user_on(user.id, ~D[2027-03-17]) == "Europe/Berlin"
      assert Travel.timezone_for_user_on(user.id, ~D[2027-04-07]) == "America/New_York"
    end

    test "returns the default for a nil user" do
      assert Travel.timezone_for_user_on(nil, ~D[2027-03-17]) == Profiles.get_default_timezone()
    end

    test "returns the default for a user with no profile" do
      user = insert(:user)

      assert Travel.timezone_for_user_on(user.id, ~D[2027-03-17]) ==
               Profiles.get_default_timezone()
    end
  end
end
