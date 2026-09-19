defmodule Tymeslot.Emails.Templates.CalendarSyncErrorTravelTest do
  @moduledoc """
  Drives `CalendarSyncError.owner_start_time/1` (private) through its real
  entry point, `CalendarSyncError.render_both/2`. Like
  `ExternalBookingChange`, this template prints only a formatted local time,
  no raw zone name, so the assertions read the resolved zone back out of the
  rendered hour (12h/AM-PM for the "en" locale this email always renders in).

  Found while auditing every `Profiles.get_user_timezone/1` call site in
  `lib/tymeslot/emails/` after fixing the third host-facing resolver
  (`BookingApprovalRequest.host_timezone/1`) in this same fix round — this
  was a fourth site neither the original task brief nor that fix round's
  scope had inventoried, so it is fixed and covered here for the same
  reason: a host-addressed email disagreeing with every other host email
  about which zone the host is in is exactly the failure this feature exists
  to prevent.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :emails
  @moduletag :availability
  @moduletag :unit

  import Tymeslot.Factory

  alias Tymeslot.Availability.Travel
  alias Tymeslot.Emails.Templates.CalendarSyncError

  setup do
    profile = insert(:profile, timezone: "America/New_York")

    {:ok, _trip} =
      Travel.create_period(profile, %{
        label: "Berlin",
        start_date: ~D[2027-03-14],
        end_date: ~D[2027-03-28],
        timezone: "Europe/Berlin"
      })

    %{user: profile.user}
  end

  describe "owner_start_time/1 via CalendarSyncError.render_both/2" do
    test "a meeting during a trip shows the host the trip's zone", %{user: user} do
      meeting =
        insert(:meeting,
          organizer_user: user,
          start_time: ~U[2027-03-17 14:00:00Z],
          end_time: ~U[2027-03-17 15:00:00Z]
        )

      {_html, text} = CalendarSyncError.render_both(meeting, :network_error)

      # 14:00 UTC is 03:00 PM in Europe/Berlin (CET on this date) and
      # 10:00 AM in America/New_York (EDT). Fails if the resolver stops
      # asking `Travel` for the trip in effect on the meeting's date.
      assert text =~ "03:00 PM"
      refute text =~ "10:00 AM"
    end

    test "a meeting outside every trip shows the host the home zone", %{user: user} do
      meeting =
        insert(:meeting,
          organizer_user: user,
          start_time: ~U[2027-04-07 14:00:00Z],
          end_time: ~U[2027-04-07 15:00:00Z]
        )

      {_html, text} = CalendarSyncError.render_both(meeting, :network_error)

      assert text =~ "10:00 AM"
      refute text =~ "04:00 PM"
    end
  end
end
