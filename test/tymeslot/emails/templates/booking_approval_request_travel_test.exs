defmodule Tymeslot.Emails.Templates.BookingApprovalRequestTravelTest do
  @moduledoc """
  Drives `BookingApprovalRequest.host_timezone/1` (private) through its real
  entry point, `BookingApprovalRequest.render/4`. The plain-text body prints
  the raw resolved zone via its "Timezone:" line, so no formatting trickery
  is needed to read the resolver's answer back out.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :emails
  @moduletag :availability
  @moduletag :unit

  import Tymeslot.Factory

  alias Ecto.UUID
  alias Tymeslot.Availability.Travel
  alias Tymeslot.Emails.Templates.BookingApprovalRequest
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting

  @urls %{
    review_url: "https://example.com/meeting-request/tok",
    approve_url: "https://example.com/meeting-request/tok?intent=approve",
    decline_url: "https://example.com/meeting-request/tok?intent=decline"
  }

  defp meeting(organizer_user_id, start_time) do
    %Meeting{
      id: UUID.generate(),
      uid: "abc-123",
      title: "Strategy call",
      meeting_type: "Strategy call",
      organizer_user_id: organizer_user_id,
      start_time: start_time,
      end_time: DateTime.add(start_time, 30, :minute),
      duration: 30,
      location: "Video Call",
      organizer_name: "Sam Host",
      organizer_email: "sam@example.com",
      attendee_name: "Alex Guest",
      attendee_email: "alex@example.com",
      attendee_message: "Hoping to talk about Q4.",
      attendee_timezone: "Europe/Ljubljana",
      attendee_locale: "en",
      status: "awaiting_approval"
    }
  end

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

  describe "host_timezone/1 via BookingApprovalRequest.render/4" do
    test "a request for a meeting during a trip shows the host the trip's zone", %{user: user} do
      email =
        BookingApprovalRequest.render(
          :request,
          meeting(user.id, ~U[2027-03-17 14:00:00Z]),
          @urls,
          "en"
        )

      assert email.text_body =~ "Europe/Berlin"
      refute email.text_body =~ "America/New_York"
    end

    test "a request for a meeting outside every trip shows the host the home zone", %{
      user: user
    } do
      email =
        BookingApprovalRequest.render(
          :request,
          meeting(user.id, ~U[2027-04-07 14:00:00Z]),
          @urls,
          "en"
        )

      assert email.text_body =~ "America/New_York"
      refute email.text_body =~ "Europe/Berlin"
    end
  end
end
