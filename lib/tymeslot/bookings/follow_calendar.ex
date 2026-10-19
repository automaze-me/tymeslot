defmodule Tymeslot.Bookings.FollowCalendar do
  @moduledoc """
  Moves a booking to the time its calendar event now has, after the host
  moved the event in their own calendar. `Tymeslot.Meetings.CalendarMove`
  decides when the host is offered that.

  What follows the move is what follows a reschedule: availability, the
  provider's video room, reminders re-pinned to the new time, the reschedule
  emails to the attendee, the organiser and the guests, and the webhook,
  Telegram and Slack dispatches. What `Tymeslot.Bookings.Reschedule` checks
  before it moves a booking is left out, because only Tymeslot choosing the
  time needs it: the host picked this time in their calendar, so no policy,
  availability, calendar or conflict check second-guesses it, no approval
  gate applies and the location stays. The calendar already holds the time,
  so nothing is written back to it; a write-back would only echo the event
  onto itself.

  The duration follows the event's length, and the event's end becomes the
  one a later end change in the calendar is measured against
  (`seen_calendar_end_time`), as when the meeting follows an end change
  (`Tymeslot.Meetings.ExternalCalendarChanges.apply_end_change/2`).
  """

  require Logger

  alias Tymeslot.Availability
  alias Tymeslot.Bookings.RescheduleLocation
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Meetings.MeetingCalendarQueries
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.VideoRooms
  alias Tymeslot.Notifications.{Events, Orchestrator}
  alias Tymeslot.Repo
  alias Tymeslot.Workers.VideoSyncWorker

  @doc """
  Moves `meeting` to `start_time`–`end_time`. The caller guarantees the
  meeting is eligible; this checks nothing.
  """
  @spec execute(MeetingSchema.t(), DateTime.t(), DateTime.t()) ::
          {:ok, MeetingSchema.t()} | {:error, :failed_to_update_meeting}
  def execute(%MeetingSchema{} = meeting, %DateTime{} = start_time, %DateTime{} = end_time) do
    case Repo.transaction(fn -> write(meeting, start_time, end_time) end) do
      {:ok, updated} ->
        announce(updated, meeting)
        {:ok, updated}

      {:error, reason} ->
        Logger.warning("Failed to move the meeting to its calendar event's time",
          meeting_id: meeting.id,
          reason: LogFormat.reason(reason)
        )

        {:error, :failed_to_update_meeting}
    end
  end

  # Written as `Reschedule` writes a new time, less its conflict check: under
  # the row's lock, with the calendar revision moved on from the row as it
  # stands, and with the reminders re-pinned in the same transaction, so they
  # commit with the new time or not at all.
  defp write(meeting, start_time, end_time) do
    with {:ok, current} <- MeetingQueries.get_meeting_for_update(meeting.id),
         {:ok, updated} <-
           MeetingQueries.update_meeting(current, attrs(current, start_time, end_time)),
         :ok <- repin_reminders(updated) do
      :ok = MeetingCalendarQueries.put_seen_calendar_end(updated.id, updated.end_time)
      # Everyone is told the new times, so an end change still waiting to be
      # announced has nothing left to say.
      :ok = MeetingCalendarQueries.clear_notified_ends(updated.id)
      updated
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # Reminders already sent were pinned to the old time, so their tracking is
  # reset and they cannot suppress the new ones. Join links that expire
  # relative to the meeting time are rebuilt for the new one before the
  # write, since the emails are rendered from the row it returns. The
  # external-change flag, and the host's dismissal of it, described the
  # difference the move removes.
  defp attrs(current, start_time, end_time) do
    Map.merge(
      %{
        start_time: start_time,
        end_time: end_time,
        duration: DateTime.diff(end_time, start_time, :minute),
        reminders_sent: [],
        reminder_email_sent: false,
        ical_sequence: current.ical_sequence + 1,
        calendar_sync_status: nil,
        calendar_sync_status_dismissed_at: nil
      },
      VideoRooms.refreshed_join_url_attrs(current, start_time)
    )
  end

  defp repin_reminders(meeting) do
    case Orchestrator.schedule_reminder_notifications(meeting, replace: true) do
      :ok -> :ok
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, {:reminders_not_settled, reason}}
    end
  rescue
    exception -> {:error, {:reminders_not_settled, exception}}
  end

  # As after a reschedule: a room still on its way owns the emails and sends
  # them once its join link exists (`RescheduleLocation.create_room/2`).
  defp announce(updated, original) do
    Availability.changed(updated.organizer_user_id)
    sync_video_room(updated)

    case RescheduleLocation.create_room(updated, original) do
      :scheduled -> :ok
      :not_scheduled -> send_notifications(updated, original)
    end
  end

  # A room that is a provider object of its own (Zoom, Meet, a Teams room on
  # another account) is moved through a retrying job. A Teams meeting attached
  # to the booking's own Outlook event moved with the event.
  defp sync_video_room(%{video_room_id: nil}), do: :ok
  defp sync_video_room(%{organizer_user_id: nil}), do: :ok

  defp sync_video_room(meeting) do
    case VideoSyncWorker.enqueue(meeting.id, "update") do
      {:ok, _status} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to enqueue provider video sync after a calendar move",
          meeting_id: meeting.id,
          reason: LogFormat.reason(reason)
        )

        :ok
    end
  end

  # The organiser's copy says the host moved the meeting rather than naming
  # the attendee (`moved_by: :host`).
  defp send_notifications(updated, original) do
    case Events.meeting_rescheduled(updated, original, moved_by: :host) do
      {:ok, _result} ->
        Logger.info("Calendar move notifications scheduled", meeting_id: updated.id)
        :ok

      {:error, reason} ->
        Logger.warning("Failed to send calendar move notifications",
          meeting_id: updated.id,
          reason: LogFormat.reason(reason)
        )

        :ok
    end
  end
end
