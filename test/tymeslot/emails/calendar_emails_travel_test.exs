defmodule Tymeslot.Emails.CalendarEmailsTravelTest do
  @moduledoc """
  Drives `CalendarEmails.resolve_owner_timezone/1` through its real entry
  point, `EmailService.send_external_booking_change/3`, rather than pinning
  it in isolation: that private function has no output visible outside the
  rendered email, so the assertions below read the resolved zone back out of
  the rendered `Formatting.format_time/2` hour, which prints in 12h/AM-PM for
  the "en" locale this email always renders in.
  """

  # async: false, mirroring `Tymeslot.Emails.EmailServiceTest`: `Delivery`
  # delivers through the email circuit-breaker rather than the test process,
  # and pointing Swoosh's `:shared_test_process` at this test — the only way
  # to observe what it sent — is a global setting, so no other test may run
  # alongside.
  use Tymeslot.DataCase, async: false

  @moduletag :emails
  @moduletag :availability
  @moduletag :unit

  import Tymeslot.Factory

  alias Tymeslot.Availability.Travel
  alias Tymeslot.Emails.EmailService

  setup do
    Application.put_env(:swoosh, :shared_test_process, self())
    on_exit(fn -> Application.delete_env(:swoosh, :shared_test_process) end)

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

  defp next_email do
    assert_received {:email, email}
    email
  end

  describe "resolve_owner_timezone/1 via send_external_booking_change/3" do
    test "a meeting during a trip is announced to the host in the trip's zone", %{user: user} do
      meeting =
        insert(:meeting,
          organizer_user_id: user.id,
          start_time: ~U[2027-03-17 14:00:00Z],
          end_time: ~U[2027-03-17 15:00:00Z]
        )

      assert {:ok, _response} =
               EmailService.send_external_booking_change(
                 meeting,
                 meeting.organizer_email,
                 :deleted
               )

      email = next_email()

      # 14:00 UTC is 03:00 PM in Europe/Berlin (CET, UTC+1 on this date) and
      # 10:00 AM in America/New_York (EDT, UTC-4). This fails if the resolver
      # stops asking `Travel` for the trip in effect on the meeting's date.
      assert email.text_body =~ "03:00 PM"
      refute email.text_body =~ "10:00 AM"
    end

    test "a meeting outside every trip is announced to the host in the home zone", %{user: user} do
      meeting =
        insert(:meeting,
          organizer_user_id: user.id,
          start_time: ~U[2027-04-07 14:00:00Z],
          end_time: ~U[2027-04-07 15:00:00Z]
        )

      assert {:ok, _response} =
               EmailService.send_external_booking_change(
                 meeting,
                 meeting.organizer_email,
                 :deleted
               )

      email = next_email()

      # Outside the trip window: 14:00 UTC is 10:00 AM in America/New_York
      # (EDT) and 04:00 PM in Europe/Berlin (CEST, UTC+2 by this date). This
      # fails if the resolver ignores the date and always returns the trip
      # zone.
      assert email.text_body =~ "10:00 AM"
      refute email.text_body =~ "04:00 PM"
    end
  end
end
