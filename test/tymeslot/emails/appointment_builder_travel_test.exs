defmodule Tymeslot.Emails.AppointmentBuilderTravelTest do
  use Tymeslot.DataCase, async: true

  @moduletag :emails
  @moduletag :availability
  @moduletag :unit

  import Tymeslot.Factory

  alias Tymeslot.Availability.Travel

  describe "owner timezone resolution" do
    test "a meeting during a trip resolves to the trip zone even when booked from home" do
      user = insert(:user)
      profile = insert(:profile, user: user, timezone: "America/New_York")

      {:ok, trip} =
        Travel.create_period(profile, %{
          label: "Berlin",
          start_date: ~D[2027-03-14],
          end_date: ~D[2027-03-28],
          timezone: "Europe/Berlin"
        })

      assert trip.timezone == "Europe/Berlin"

      # The meeting falls inside the trip; "now" is irrelevant to the answer.
      assert Travel.timezone_for_user_on(user.id, ~D[2027-03-17]) == "Europe/Berlin"

      # A meeting after the trip is announced in the home zone.
      assert Travel.timezone_for_user_on(user.id, ~D[2027-04-07]) == "America/New_York"
    end
  end
end
