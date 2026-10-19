defmodule Tymeslot.Bookings.RescheduleFollowCalendarTest do
  @moduledoc """
  `Reschedule.follow_calendar/3` against the real email service: a host moved
  a booked meeting in their own calendar, and the booking follows that time.

  The move must do everything a reschedule does afterwards (emails, reminders,
  webhooks, video room) and nothing that chooses or writes the time: the
  calendar already holds it.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :integration

  import Mox
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Ecto.UUID
  alias Tymeslot.Availability.WeeklySchedule
  alias Tymeslot.Bookings.Reschedule
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.CalendarEventWorker
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.VideoSyncWorker
  alias Tymeslot.Workers.WebhookWorker

  setup :verify_on_exit!

  setup do
    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      telegram_notifications_allowed: true,
      telegram_shared_bot: false
    )

    TestMocks.setup_email_mocks()

    # The reschedule submit re-reads the host's connected calendars

    # (`Tymeslot.Bookings.CalendarCheck`); these tests are about a host with

    # nothing else in their diary.

    TestMocks.stub_no_calendar_events()

    # The real service, so the templates actually render. Restored afterwards
    # for the rest of the suite.
    original_service = Application.get_env(:tymeslot, :email_service_module)
    Application.put_env(:tymeslot, :email_service_module, Tymeslot.Emails.EmailService)

    # `Delivery.deliver/1` runs inside the circuit-breaker GenServer, so
    # Swoosh's test adapter would otherwise post `{:email, _}` to that process
    # rather than to this one. Pointing the adapter at this test collects the
    # rendered emails here instead. Safe because the module is `async: false`:
    # no other test runs while these do.
    Application.put_env(:swoosh, :shared_test_process, self())

    on_exit(fn ->
      Application.put_env(:tymeslot, :email_service_module, original_service)
      Application.delete_env(:swoosh, :shared_test_process)
    end)

    user = insert(:user)
    profile = insert(:profile, user: user, timezone: "Europe/Berlin")

    # The booking policy lives on the schedule now, not the profile; these tests
    # only need one to exist so the reschedule resolves a policy at all. It
    # must offer every hour of every day: reschedule now refuses a time the
    # organiser's schedule doesn't offer, and these tests pick
    # `future_datetime/2`, a fixed mid-day time.
    schedule =
      insert(:availability_schedule,
        profile: profile,
        is_default: true,
        buffer_before_minutes: 15,
        buffer_after_minutes: 15
      )

    for day_of_week <- 1..7 do
      {:ok, _day} =
        WeeklySchedule.create_day_availability(schedule.id, day_of_week, %{
          is_available: true,
          start_time: ~T[00:00:00],
          end_time: ~T[23:59:00]
        })
    end

    insert(:webhook, user: user, events: ["meeting.rescheduled"])
    insert(:telegram_integration, user: user, events: ["meeting.rescheduled"])

    %{user: user, profile: profile}
  end

  describe "follow_calendar/3" do
    test "moves the meeting and follows a changed length", %{user: user} do
      meeting = insert_future_meeting(user)
      {new_start, new_end} = new_times(meeting)

      assert {:ok, updated} = Reschedule.follow_calendar(meeting, new_start, new_end)

      assert updated.start_time == new_start
      assert updated.end_time == new_end
      assert updated.duration == 45
      assert Repo.get!(MeetingSchema, meeting.id).duration == 45
    end

    test "advances ical_sequence and clears the external-change flag", %{user: user} do
      meeting = insert_future_meeting(user, calendar_sync_status: "externally_modified")
      {new_start, new_end} = new_times(meeting)

      assert {:ok, updated} = Reschedule.follow_calendar(meeting, new_start, new_end)

      assert updated.ical_sequence == meeting.ical_sequence + 1
      assert updated.calendar_sync_status == nil
    end

    test "writes nothing to the calendar", %{user: user} do
      meeting = insert_future_meeting(user)
      {new_start, new_end} = new_times(meeting)

      assert {:ok, _updated} = Reschedule.follow_calendar(meeting, new_start, new_end)

      refute_enqueued(worker: CalendarEventWorker)
    end

    test "re-pins the reminders to the new time", %{user: user} do
      meeting = insert_future_meeting(user, reminders_sent: [%{"value" => 24, "unit" => "hours"}])
      {new_start, new_end} = new_times(meeting)

      assert {:ok, updated} = Reschedule.follow_calendar(meeting, new_start, new_end)

      assert updated.reminders_sent == []

      jobs = all_enqueued(worker: EmailWorker, args: %{"action" => "send_reminder_emails"})
      assert jobs != []

      for job <- jobs do
        assert DateTime.compare(job.scheduled_at, new_start) == :lt
        assert DateTime.compare(job.scheduled_at, meeting.start_time) == :gt
      end
    end

    test "emails the attendee and the organiser", %{user: user} do
      meeting = insert_future_meeting(user)
      {new_start, new_end} = new_times(meeting)

      assert {:ok, _updated} = Reschedule.follow_calendar(meeting, new_start, new_end)

      delivered = delivered_emails()

      assert delivered[meeting.attendee_email].subject =~ "Rescheduled"
      assert delivered[meeting.organizer_email].subject =~ "Rescheduled"
    end

    test "resets and emails the booking's guests", %{user: user} do
      meeting = insert_future_meeting(user)
      {new_start, new_end} = new_times(meeting)

      {:ok, guest} =
        GuestQueries.insert_guest(%{meeting_id: meeting.id, email: "guest@example.com"})

      {:ok, _} = GuestQueries.update_rsvp(guest, %{status: "accepted"})

      assert {:ok, _updated} = Reschedule.follow_calendar(meeting, new_start, new_end)

      assert [%{status: "pending"}] = GuestQueries.list_for_meeting(meeting.id)
      assert_received {:email, %{to: [{_name, "guest@example.com"}]}}
    end

    test "dispatches meeting.rescheduled", %{user: user} do
      meeting = insert_future_meeting(user)
      {new_start, new_end} = new_times(meeting)

      assert {:ok, _updated} = Reschedule.follow_calendar(meeting, new_start, new_end)

      assert all_enqueued(worker: WebhookWorker) != []
    end

    test "moves a separate video room", %{user: user} do
      meeting = insert_future_meeting(user, video_room_id: "room-1")
      {new_start, new_end} = new_times(meeting)

      assert {:ok, _updated} = Reschedule.follow_calendar(meeting, new_start, new_end)

      assert_enqueued(
        worker: VideoSyncWorker,
        args: %{"meeting_id" => meeting.id, "action" => "update"}
      )
    end
  end

  # ----- helpers -----

  defp new_times(meeting) do
    new_start = DateTime.add(meeting.start_time, 2, :day)
    {new_start, DateTime.add(new_start, 45, :minute)}
  end

  # Every email the move sends, keyed by recipient address.
  defp delivered_emails do
    assert_received {:email, first}
    assert_received {:email, second}

    Map.new([first, second], fn email ->
      {email.to |> hd() |> elem(1), email}
    end)
  end

  defp insert_future_meeting(user, attrs \\ []) do
    start_time = future_datetime(3, :day)

    insert(
      :meeting,
      Keyword.merge(
        [
          uid: UUID.generate(),
          organizer_user_id: user.id,
          organizer_email: "organiser-#{user.id}@example.com",
          start_time: start_time,
          end_time: DateTime.add(start_time, 30, :minute),
          duration: 30,
          status: "confirmed"
        ],
        attrs
      )
    )
  end

  defp future_datetime(amount, unit) do
    future = DateTime.add(DateTime.utc_now(), amount, unit)

    %{future | hour: 10, minute: 0, second: 0, microsecond: {0, 0}}
  end
end
