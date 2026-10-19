defmodule Tymeslot.Meetings.ExternalCalendarChangesPendingWriteTest do
  @moduledoc """
  A sync can see a calendar event before Tymeslot's own queued write to it has
  landed (an attendee reschedule moves the booking at once and the calendar a
  few seconds later). Flagging then would offer the host to undo the
  attendee's reschedule, so a modification is not flagged while such a write
  is pending.
  """

  use Tymeslot.DataCase, async: false

  import Ecto.Query
  import Tymeslot.Factory

  @moduletag :meetings
  @moduletag :calendar

  alias Oban.Job
  alias Tymeslot.Bookings.CalendarJobs
  alias Tymeslot.Meetings.ExternalCalendarChanges
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  setup do
    TestMocks.setup_email_mocks()
    user = insert(:user)
    integration = insert(:calendar_integration, user: user)

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        status: "confirmed",
        calendar_integration_id: integration.id,
        provider_event_id: "evt-pending"
      )

    %{meeting: meeting}
  end

  defp reload(meeting) do
    {:ok, reloaded} = MeetingQueries.get_meeting(meeting.id)
    reloaded
  end

  test "a modification seen while Tymeslot's own write is pending does not flag the meeting",
       %{meeting: meeting} do
    {:ok, _job} = CalendarJobs.schedule_job(meeting, "update")

    assert :ok = ExternalCalendarChanges.apply_change_to_meeting(meeting, :modified)

    assert reload(meeting).calendar_sync_status == nil
  end

  test "once that write has finished, the modification flags the meeting", %{meeting: meeting} do
    {:ok, _job} = CalendarJobs.schedule_job(meeting, "update")
    Repo.update_all(from(j in Job), set: [state: "completed"])

    assert :ok = ExternalCalendarChanges.apply_change_to_meeting(meeting, :modified)

    assert reload(meeting).calendar_sync_status == "externally_modified"
  end
end
