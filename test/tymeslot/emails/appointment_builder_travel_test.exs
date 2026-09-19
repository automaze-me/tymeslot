defmodule Tymeslot.Emails.AppointmentBuilderTravelTest do
  use Tymeslot.DataCase, async: true

  @moduletag :emails
  @moduletag :availability
  @moduletag :unit

  import Tymeslot.Factory

  alias Tymeslot.Availability.Travel
  alias Tymeslot.Emails.AppointmentBuilder

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

  # These, unlike the describe block above, drive the production entry point
  # this task actually changed (`AppointmentBuilder.from_meeting/1`) rather
  # than `Travel` directly. Each assertion below fails if the corresponding
  # production edit in `lib/tymeslot/emails/appointment_builder.ex` is
  # reverted — confirmed by temporarily reverting it and re-running (see the
  # fix-round report).
  describe "AppointmentBuilder.from_meeting/1 during a trip" do
    setup do
      user = insert(:user)
      profile = insert(:profile, user: user, timezone: "America/New_York")

      {:ok, _trip} =
        Travel.create_period(profile, %{
          label: "Berlin",
          start_date: ~D[2027-03-14],
          end_date: ~D[2027-03-28],
          timezone: "Europe/Berlin"
        })

      %{user: user}
    end

    test "the host-facing zone is the trip's zone for a meeting inside the trip", %{user: user} do
      meeting =
        insert(:meeting,
          organizer_user_id: user.id,
          start_time: ~U[2027-03-17 14:00:00Z],
          end_time: ~U[2027-03-17 15:00:00Z]
        )

      result = AppointmentBuilder.from_meeting(meeting)

      assert %DateTime{time_zone: "Europe/Berlin"} = result.start_time_owner_tz
    end

    test "the host-facing zone is the home zone for a meeting outside every trip", %{user: user} do
      meeting =
        insert(:meeting,
          organizer_user_id: user.id,
          start_time: ~U[2027-04-07 14:00:00Z],
          end_time: ~U[2027-04-07 15:00:00Z]
        )

      result = AppointmentBuilder.from_meeting(meeting)

      assert %DateTime{time_zone: "America/New_York"} = result.start_time_owner_tz
    end
  end
end
