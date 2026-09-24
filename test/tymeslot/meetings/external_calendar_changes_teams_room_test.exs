defmodule Tymeslot.Meetings.ExternalCalendarChangesTeamsRoomTest do
  @moduledoc """
  A Teams room is a calendar event in its own right, sitting in the organiser's
  mailbox beside the booking's own event. Deleting it means the video room is
  gone — not that the booking was called off.

  This is the shape of the incident that produced
  https://github.com/Tymeslot/tymeslot/issues/143: the meeting's `uid` had been
  overwritten with the Teams event's id, so removing that event from Outlook
  read as the booking having been deleted externally, and the sync cancelled a
  live booking and emailed the attendee about it.

  Removing the overwrite is not on its own enough: anything else that teaches
  the change matcher to recognise a meeting by its `video_room_id` reopens the
  same path, which is what these tests pin down.
  """

  use Tymeslot.DataCase, async: true

  import Tymeslot.Factory

  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.MeetingQueries

  @teams_event_id "AAMkAGI2TGuLAAA="
  @booking_event_id "AAMkAGI2BookingAAA="

  defp teams_booking(_context) do
    user = insert(:user)
    integration = insert(:calendar_integration, user: user, provider: "outlook")

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        calendar_integration_id: integration.id,
        provider_event_id: @booking_event_id,
        video_provider: "teams",
        video_room_id: @teams_event_id,
        status: "confirmed"
      )

    %{integration: integration, meeting: meeting}
  end

  setup :teams_booking

  describe "a deleted Teams room event" do
    test "leaves the booking alone", %{integration: integration, meeting: meeting} do
      assert :ok =
               Meetings.apply_external_calendar_change(
                 integration.id,
                 @teams_event_id,
                 nil,
                 :deleted
               )

      {:ok, reloaded} = MeetingQueries.get_meeting(meeting.id)

      assert reloaded.status == "confirmed"
      assert reloaded.calendar_sync_status == nil
    end
  end

  describe "a deleted booking event" do
    test "still cancels the booking", %{integration: integration, meeting: meeting} do
      assert :ok =
               Meetings.apply_external_calendar_change(
                 integration.id,
                 @booking_event_id,
                 nil,
                 :deleted
               )

      {:ok, reloaded} = MeetingQueries.get_meeting(meeting.id)

      refute reloaded.status == "confirmed"
    end
  end
end
