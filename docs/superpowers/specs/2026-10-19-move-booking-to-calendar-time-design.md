# Move a booking to the time its calendar event was moved to

**Status:** design, approved 2026-10-19
**Date:** 2026-10-19
**Branch:** to be cut from `merge-upstream-1.26.0`
**Fork:** `automaze-me/tymeslot`, written to be offered upstream as an issue
and PR afterwards

## Problem

The host moves a booked meeting in their own calendar (Outlook, in the case
that prompted this). The booking in Tymeslot stays at the old time, and so do
the attendee's reminder emails, the most visible part for the attendee: they
are reminded of a time that no longer holds.

Today Tymeslot notices the move (`Calendar.Sync.post_commit_reconciliation/2`
compares the synced event with the booking it mirrors) and does three things:
it sets `calendar_sync_status` to `"externally_modified"`, shows a warning on
the meeting's card in the dashboard ("This meeting's event was rescheduled in
your external calendar", with a Dismiss button), and emails the host
(`ExternalBookingChange`, "Action required: Meeting Rescheduled in External
Calendar"), asking them to update the booking in Tymeslot. There is no way to
do that. The dashboard's only option is Reschedule, which sends the attendee
a reschedule request: it voids the slot, deletes the calendar event and asks
the attendee to pick a new time, although host and attendee have already
agreed one.

(Detection itself was incomplete for Outlook: the 15-minute delta sweep never
reconciled, so without a working Graph subscription a move was never noticed.
That is fixed separately in `c2674f191` and is not part of this design.)

## Intent

Give the host the missing step: one click on the warning that makes Tymeslot
follow the calendar. The booking takes the event's new time and everything
that hangs off the booking time follows it, above all the reminder emails.

The host decides; nothing moves on its own. This keeps upstream's design
(detect, flag, tell the host) intact and only completes it, which is what
makes it a reasonable upstream contribution. It also sidesteps the hard part
of moving automatically: telling a move the host made in their calendar apart
from Tymeslot's own write to the calendar that has not landed yet (an
attendee's reschedule in flight), which an automatic move would have to get
right every time or silently undo the attendee's choice.

## Goals

- On the warning card of a booking flagged `"externally_modified"`, a second
  button beside Dismiss: "Move booking to <date, time>", showing the time the
  calendar event has now.
- Clicking it (after a confirmation) moves the booking to that time:
  - `start_time` and `end_time` take the event's, so the duration follows
    when the host also changed the event's length (`duration` updated to
    match);
  - the attendee's reminder emails are re-pinned to the new time, and
    reminders already sent for the old time do not suppress the new ones
    (`reminders_sent: []`, `reminder_email_sent: false`, as
    `Bookings.Reschedule` resets them);
  - join links that are only valid relative to the meeting time are rebuilt
    (`VideoRooms.refreshed_join_url_attrs/2`, as `Reschedule` does), and a
    video room that is a separate provider object (Zoom, Meet, a Teams room
    on another account) is moved through `VideoSyncWorker` "update", as
    `Reschedule` does; a Teams meeting attached to the booking's own Outlook
    event has already moved with the event;
  - the attendee, the host and the booking's guests get Tymeslot's ordinary
    reschedule emails (see "Who is emailed");
  - webhooks, Telegram and Slack get the usual `meeting.rescheduled`;
  - availability is refreshed;
  - the warning clears (`calendar_sync_status` back to `nil`).
- The host also gets a short confirmation in the dashboard (flash).
- The `ExternalBookingChange` email for a modification says the booking can
  be moved from the dashboard, and its button leads to the dashboard's
  meetings list (today it leads to the attendee's public meeting page).

## Non-goals

- Moving the booking automatically, without the host's click.
- Moving it from the email with one click. That needs a signed action link
  (as approvals have); the email leads to the dashboard instead.
- Group meetings. A group slot cannot be moved for everyone at once
  (`Reschedule` refuses it too); their warning keeps Dismiss only, and the
  email's group wording stays as it is.
- Anything for `"externally_deleted"`, which already cancels the booking.
- Choosing a different time than the event's. That is what the attendee
  reschedule flow and the reschedule request are for.

## Anti-goals

- **Writing to the calendar.** The event already has the new time. Writing
  the booking back (`CalendarJobs` "update") would at best do nothing and at
  worst overwrite edits the host made to the event, and on Outlook it can
  send the attendee a second update.
- **Refusing the move on availability grounds.** The host already chose the
  time in their own calendar. No schedule, buffer, notice or booking-limit
  check applies, and an overlap with another Tymeslot booking does not block
  it.

## Who is emailed

The rule the host set: Tymeslot stays quiet only towards someone the calendar
has already fully informed. Nobody qualifies, so the action sends exactly
what an ordinary reschedule sends
(`Orchestrator.send_reschedule_notifications/2`):

- **The attendee.** Outlook (or Google) tells them about the move when they
  are on the event, but that updates only the calendar's own entry. Every
  confirmation email from Tymeslot also carries a calendar file of its own,
  with its own UID (`IcsGenerator`), which many mail apps add to the
  calendar; that second entry stays at the old time unless Tymeslot sends
  its reschedule email with the updated file (`ical_sequence` advanced). On
  CalDAV, Tymeslot writes events with `SCHEDULE-AGENT=CLIENT`, so the server
  never notifies anyone and Tymeslot's email is the only notice.
- **The host**, whose reschedule copy doubles as the record of the move.
- **The booking's guests** (`meeting_guests`). They are not on the calendar
  event (`Meetings.attendees_for_calendar/1` is empty for a one-to-one
  booking, and the providers' mappers name only the attendee), so no
  calendar ever tells them. They get `GuestNotifications.notify_rescheduled/2`
  as on any reschedule: RSVP reset to pending, sent reminders cleared, the
  new time emailed.

The attendee may hear about the move twice, from their calendar and from
Tymeslot; that is accepted so that no copy of the meeting stays at the old
time.

## Tymeslot's own calendar writes

*Builder-check finding, settled as a design call.* When the attendee
reschedules through Tymeslot, the booking takes the new time at once and the
write to the calendar follows as a `CalendarEventWorker` job. A sync that
runs before that write lands still sees the old time and flags the booking,
and the card would then offer to move it back, undoing the attendee's
choice; a write that keeps retrying or fails holds that window open.
Therefore:

- while a calendar job for the booking is still unfinished (available,
  scheduled, executing or retryable), detection does not flag it and the
  card offers no move;
- every time change Tymeslot makes itself (`Reschedule`, and this action)
  clears `calendar_sync_status`, so a flag raised before the change cannot
  outlive it.

## When the button is offered

Only when all of these hold, checked again on click:

- the booking is `"externally_modified"` and not dismissed;
- it is not a group meeting;
- its status is `"confirmed"`; a request still awaiting approval or payment
  keeps Dismiss only (moving the host's tentative hold is a different
  conversation with the invitee);
- its linked event is still in the cache, is a timed event (not all-day),
  and differs from the booking;
- the event's new start is not in the past;
- no Tymeslot calendar job for the booking is still unfinished (see above).

If the event changed again between the page rendering and the click, the
click uses the event's time as it is at the click, and the confirmation says
which time that is. If the event is gone or no longer qualifies, the click
does nothing to the booking and says why.

## Constraints

- Provider-agnostic. The flag, the card and the email are shared by Google,
  Outlook and CalDAV-family integrations, so the action reads the linked
  event from the local cache (`provider_calendar_events`, matched by
  `CalendarEventLink`'s identity rule), never from a provider API.
- Built from upstream's existing pieces rather than parallel ones: the time
  update and its side effects should reuse what `Bookings.Reschedule` and
  `Notifications.Events.meeting_rescheduled/2` already do, minus the
  calendar write, the approval gate and the availability checks. If that
  needs a small refactor of `Reschedule` to expose the shared part, prefer
  that over copying it.
- New user-facing strings go through gettext and are translated for every
  shipped locale (the completeness test requires it).
- The dashboard action is scoped to the signed-in organiser, as Dismiss is.
- `ical_sequence` moves on, as on every reschedule, so a later cancellation
  or reschedule ICS from Tymeslot supersedes what the attendee holds.

## Left to the builder

- Module placement and naming (likely beside `ExternalCalendarChanges` in
  `Tymeslot.Meetings`, exposed through the `Meetings` context).
- The exact copy of the button, the dialog and the email change, in the
  existing dashboard and email wording style.
- How the card finds the event's current time for its label (a lookup per
  flagged card is fine; flagged cards are rare).
- Telemetry, following the dashboard's existing meeting events.

## Testing

- Domain: a flagged booking moves to the event's time; reminders are
  re-pinned (old jobs gone, new ones at the new time, sent-tracking reset);
  no calendar job is enqueued; `meeting.rescheduled` is dispatched; the
  attendee and the host get the reschedule emails, carrying the new time and
  an advanced `ical_sequence`; guests are reset and emailed; group,
  non-confirmed, all-day, past,
  vanished-event and pending-write cases are refused; a duration change
  follows.
- Detection: no flag while a calendar job for the booking is unfinished;
  `Reschedule` clears an existing flag.
- Dashboard: the button appears only when offered, shows the event's time,
  and clicking through the dialog moves the booking and clears the warning.
- Email: the modification email's new line and button target.
