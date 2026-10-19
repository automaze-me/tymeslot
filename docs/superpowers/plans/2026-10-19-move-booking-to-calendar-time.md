# Move a booking to its calendar event's new time — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A button on a flagged meeting card that moves the booking to the time its calendar event was moved to, with reminders, guests, video and notifications following.

**Architecture:** Detection already flags the booking (`ExternalCalendarChanges`). A new `Tymeslot.Meetings.CalendarMove` decides whether a move is offered and at what time (read from the event cache), and performs it through a new `Bookings.Reschedule.follow_calendar/3`, which shares `Reschedule`'s attrs and after-commit fan-out but skips the calendar write, the approval gate and the availability checks. The dashboard shows the offer on the card and confirms in a modal; the host's email points there.

**Tech Stack:** Elixir 1.20 / Phoenix LiveView, Ecto, Oban (testing `:manual`), ExMachina, Mox, gettext.

**Spec:** `docs/superpowers/specs/2026-10-19-move-booking-to-calendar-time-design.md`

## Global Constraints

- Branch: work on `merge-upstream-1.26.0` (the fork's main is not touched).
- Toolchain runs in Docker only (no host Elixir). With `tymeslot-test-pg` started (`docker start tymeslot-test-pg`), run tests as
  `docker run --rm --user 1000:1000 --network container:tymeslot-test-pg -v ~/tymeslot:/app -v /tmp/claude-1000/-home-joern-tymeslot/4aab8f98-7076-4189-b4fc-be07effda023/scratchpad/mixhome:/home/u -e HOME=/home/u -e MIX_ENV=test -w /app tymeslot-dev:local mix test <paths>`
  and dev gates the same way with `-e MIX_ENV=dev` (no `--network` needed). Below, `MIX_TEST <paths>` and `MIX_DEV <task>` stand for these two commands.
- Gates that must stay green: `format --check-formatted`, `compile --warnings-as-errors` (dev and test), `credo --strict` (modules ≤ 650 lines; `BookingsManagementComponent` is at 614, so new handler bodies go in a split module), `gettext.check`, `xref graph --label compile-connected --fail-above 26` (no new compile-time dependencies: no module attributes computed from other modules' functions, no new `import`/`use` of app modules).
- Every new test module carries domain `@moduletag`s (credo `TestModuleTagRequired`); look at a neighbouring test for the tags.
- Every new user-facing string is wrapped in `dgettext` and translated in `cs de fr it pl pt uk` (`en` keeps `msgstr ""`), following `priv/gettext/TRANSLATING.md` and the locale's `GLOSSARY.<locale>.md`; `test/tymeslot_web/gettext_completeness_test.exs` must pass.
- No calendar write anywhere on the move path: no `CalendarJobs.schedule_job/2`, no `CalendarEventScheduler` call.
- No availability, buffer, notice or booking-limit check on the move path; an overlap with another booking does not block it.
- The move is offered and performed only for `status == "confirmed"`, non-group meetings flagged `"externally_modified"` and not dismissed.
- Commits: conventional (`feat(meetings): …`, `fix(…)`, `test(…)`), no "Co-Authored-By: Claude" trailer, no Claude Code footer.
- Known unrelated failure: `TimezoneChangeAvailabilityTest` (2 tests) fails on Mondays, also on clean upstream.

## Review Focus

1. The event moved again between the list rendering and the click: the move must use the cache's time at the click, and the modal must show that time (Task 4 test "uses the cached time at the moment of the move"; Task 5 opens the modal from a fresh offer).
2. A double click or two tabs: the second move must be refused, not applied twice (Task 4 test "a second move is refused").
3. A forged meeting id from another organiser: refused with no change (Task 4 `:not_found` test; Task 5 cross-tenant test).
4. Cached times with microseconds or an end not after the start: offers carry second-precision UTC times, and a malformed event is refused as `:invalid_times` (Task 4 tests).
5. A flag raised while Tymeslot's own write is pending must never offer a move back (Task 2 detection test, Task 4 `:calendar_write_pending` test).

---

### Task 1: Ask whether a meeting still has an unfinished job of a worker

**Files:**
- Modify: `lib/tymeslot/jobs/oban_job_queries.ex`
- Modify: `lib/tymeslot/jobs.ex`
- Test: `test/tymeslot/jobs/oban_job_queries_test.exs`

**Interfaces:**
- Produces: `Tymeslot.Jobs.pending_meeting_job?(worker :: module() | String.t(), meeting_id :: term()) :: boolean()` (delegates to `ObanJobQueries.pending_meeting_job?/2`). True while a job of `worker` whose `args["meeting_id"]` equals `to_string(meeting_id)` is in `available`, `scheduled`, `executing`, `retryable` or `suspended`.

- [ ] **Step 1: Write the failing tests** in `oban_job_queries_test.exs`, a `describe "pending_meeting_job?/2"` with:
  - `"is true for a queued calendar job of the meeting"`: `{:ok, :scheduled} = CalendarJobs.schedule_job(%{id: meeting_id}, "update")`, then `assert ObanJobQueries.pending_meeting_job?(CalendarEventWorker, meeting_id)`.
  - `"is false once that job has completed"`: same insert, then `Repo.update_all(Oban.Job, set: [state: "completed"])`, `refute …`.
  - `"is false for another meeting's job"`: job for one UUID, ask for another, `refute`.
  - `"is false for another worker's job"`: `Oban.insert!(EmailWorker.new(%{"meeting_id" => meeting_id, "action" => "send_reminder_emails"}))`, `refute ObanJobQueries.pending_meeting_job?(CalendarEventWorker, meeting_id)`.
- [ ] **Step 2: Run** `MIX_TEST test/tymeslot/jobs/oban_job_queries_test.exs`. Expected: the four new tests fail with `UndefinedFunctionError`.
- [ ] **Step 3: Implement** `ObanJobQueries.pending_meeting_job?/2` as a `Repo.exists?` over `Oban.Job`, matching worker through the module's existing `normalize_worker_name/1` and the meeting through `fragment("?->>'meeting_id' = ?", j.args, ^to_string(meeting_id))`; add the `defdelegate` with a one-paragraph `@doc` to `Tymeslot.Jobs`.
- [ ] **Step 4: Run** the same file. Expected: all pass.
- [ ] **Step 5: Commit** `feat(jobs): ask whether a meeting still has an unfinished job of a worker`.

### Task 2: Never flag a booking while Tymeslot's own write is pending; clear the flag on every reschedule

**Files:**
- Modify: `lib/tymeslot/meetings/external_calendar_changes.ex` (`apply_status_change/3`)
- Modify: `lib/tymeslot/bookings/reschedule.ex` (the attrs in `apply_time_update_and_schedule_job/4`)
- Create: `test/tymeslot/meetings/external_calendar_changes_pending_write_test.exs`
- Test: `test/tymeslot/bookings/reschedule_test.exs`

**Interfaces:**
- Consumes: `Jobs.pending_meeting_job?/2` (Task 1) with `Tymeslot.Workers.CalendarEventWorker`.
- Produces: `Reschedule.execute/4` now writes `calendar_sync_status: nil` and `calendar_sync_status_dismissed_at: nil` with the new times.

- [ ] **Step 1: Write the failing tests.**
  - New module `ExternalCalendarChangesPendingWriteTest` (`use Tymeslot.DataCase, async: false`), meeting inserted with `insert(:meeting, status: "confirmed", calendar_integration_id: integration.id, provider_event_id: "evt-pending")` (future times from the factory):
    - `"a modification seen while Tymeslot's own write is pending does not flag the meeting"`: `CalendarJobs.schedule_job(meeting, "update")`, then `:ok = ExternalCalendarChanges.apply_change_to_meeting(meeting, :modified)`, reload, `assert reloaded.calendar_sync_status == nil`.
    - `"once that write has finished, the modification flags the meeting"`: insert the job, mark it `completed` via `Repo.update_all`, apply `:modified`, `assert reloaded.calendar_sync_status == "externally_modified"`. Stub the host email with `TestMocks.setup_email_mocks()`.
  - In `reschedule_test.exs`, using its existing setup and helpers: `"a reschedule clears an external-change flag"`: set the meeting's `calendar_sync_status` to `"externally_modified"` and `calendar_sync_status_dismissed_at` to now, run `Reschedule.execute/4` to a valid new slot, assert both fields are `nil` on the returned meeting.
- [ ] **Step 2: Run** `MIX_TEST test/tymeslot/meetings/external_calendar_changes_pending_write_test.exs test/tymeslot/bookings/reschedule_test.exs`. Expected: the first new test and the reschedule test fail; the second new test passes already.
- [ ] **Step 3: Implement.** In `apply_status_change/3`, a `cond` clause before the update, for `signal == :modified` only: when `Jobs.pending_meeting_job?(CalendarEventWorker, meeting.id)`, `ignore(meeting, signal, "a Tymeslot calendar write for the meeting is still pending")`, with a comment saying why (the sync can see the event before Tymeslot's own write lands, and flagging then would offer to undo the attendee's reschedule; deletions stay unguarded). In `Reschedule`, add the two fields to the attrs map.
- [ ] **Step 4: Run** the two files, then the detection suites: `MIX_TEST test/tymeslot/integrations/calendar test/tymeslot/meetings test/tymeslot/workers`. Expected: all pass. A test that relied on flagging a meeting created through the booking flow while its creation job was still queued must make the scenario real (complete or remove the queued job first) rather than drop the assertion.
- [ ] **Step 5: Commit** `fix(meetings): never flag a booking while Tymeslot's own calendar write is pending`.

### Task 3: `Reschedule.follow_calendar/3`

**Files:**
- Modify: `lib/tymeslot/bookings/reschedule.ex`
- Create: `test/tymeslot/bookings/reschedule_follow_calendar_test.exs`

**Interfaces:**
- Produces: `Tymeslot.Bookings.Reschedule.follow_calendar(meeting :: MeetingSchema.t(), start_time :: DateTime.t(), end_time :: DateTime.t()) :: {:ok, MeetingSchema.t()} | {:error, :failed_to_update_meeting}`. Callers guarantee eligibility (Task 4); this function checks nothing.

- [ ] **Step 1: Write the failing tests.** Copy the setup of `test/tymeslot/bookings/reschedule_notifications_integration_test.exs` (real email service, `:shared_test_process`, webhook and Telegram integrations, `insert_future_meeting/1`) and its `delivered_emails/0` helper. Move the meeting to `new_start = DateTime.add(meeting.start_time, 2, :day)`, `new_end = DateTime.add(new_start, 45, :minute)`:
  - `"moves the meeting and follows a changed length"`: `start_time == new_start`, `end_time == new_end`, `duration == 45`.
  - `"advances ical_sequence and clears the external-change flag"`: meeting inserted with `calendar_sync_status: "externally_modified"`; after: `ical_sequence == meeting.ical_sequence + 1`, `calendar_sync_status == nil`.
  - `"writes nothing to the calendar"`: `refute_enqueued(worker: CalendarEventWorker)`.
  - `"re-pins the reminders to the new time"`: meeting inserted with `reminders_sent` non-empty; after: `reminders_sent == []`, and every `all_enqueued(worker: EmailWorker, args: %{"action" => "send_reminder_emails"})` job has `scheduled_at` before `new_start` and after `meeting.start_time`.
  - `"emails the attendee and the organiser"`: both delivered subjects `=~ "Rescheduled"`.
  - `"resets and emails the booking's guests"`: `GuestQueries.insert_guest(%{meeting_id: meeting.id, email: "guest@example.com"})` with an accepted RSVP; after: its RSVP is `"pending"` and an email reached `"guest@example.com"`.
  - `"dispatches meeting.rescheduled"`: `all_enqueued(worker: WebhookWorker) != []`.
  - `"moves a separate video room"`: meeting with `video_room_id: "room-1"`; `assert_enqueued(worker: VideoSyncWorker, args: %{"meeting_id" => meeting.id, "action" => "update"})`.
- [ ] **Step 2: Run** `MIX_TEST test/tymeslot/bookings/reschedule_follow_calendar_test.exs`. Expected: all fail with `UndefinedFunctionError`.
- [ ] **Step 3: Implement.** Extract from `apply_time_update_and_schedule_job/4` a private `time_change_attrs(meeting, start_dt, end_dt)` holding the shared attrs (times, `reschedule_requested_at: nil`, `reminders_sent: []`, `reminder_email_sent: false`, `ical_sequence + 1`, the two sync-status fields from Task 2, merged with `VideoRooms.refreshed_join_url_attrs/2`), and use it there. `follow_calendar/3` writes `time_change_attrs/3` merged with `%{duration: DateTime.diff(end_time, start_time, :minute)}` through `MeetingQueries.update_meeting/2` (no conflict check, no calendar job, no gate attributes, no location), then runs the existing `after_commit/2` with the original meeting. Its `@doc` says what it leaves out and why (the calendar already holds the time the host chose there).
- [ ] **Step 4: Run** the new file and `test/tymeslot/bookings`. Expected: all pass.
- [ ] **Step 5: Commit** `feat(bookings): follow a calendar event's new time without writing it back`.

### Task 4: `Tymeslot.Meetings.CalendarMove`

**Files:**
- Create: `lib/tymeslot/meetings/calendar_move.ex`
- Modify: `lib/tymeslot/meetings.ex` (delegates)
- Create: `test/tymeslot/meetings/calendar_move_test.exs`

**Interfaces:**
- Consumes: `Jobs.pending_meeting_job?/2` (Task 1), `Reschedule.follow_calendar/3` (Task 3), `ProviderCalendarEventQueries.get_by_identifiers/2`, `CalendarEventLink.identifiers/1`, `MeetingQueries.get_meeting_for_organizer/2`, `Tymeslot.Clock.utc_now/0`.
- Produces:
  - `@type offer :: %{start_time: DateTime.t(), end_time: DateTime.t()}` (UTC, truncated to `:second`)
  - `@type refusal :: :not_flagged | :group_meeting | :not_confirmed | :calendar_write_pending | :event_not_found | :all_day | :invalid_times | :unchanged | :in_past`
  - `CalendarMove.offer(meeting :: MeetingSchema.t()) :: {:ok, offer()} | {:error, refusal()}`, checking in the order of the refusal type above (cheap struct checks first).
  - `CalendarMove.offers(meetings :: [MeetingSchema.t()]) :: %{String.t() => offer()}`, keyed by meeting id, eligible meetings only; meetings failing the struct checks cost no query.
  - `CalendarMove.move(meeting_id :: String.t(), organizer_user_id :: integer()) :: {:ok, MeetingSchema.t()} | {:error, refusal() | :not_found | :failed_to_update_meeting}`: loads through `get_meeting_for_organizer/2`, takes a fresh `offer/1`, calls `follow_calendar/3`.
  - `Meetings.calendar_move_offer/1`, `Meetings.calendar_move_offers/1`, `Meetings.move_to_calendar_time/2` delegating to the three.

- [ ] **Step 1: Write the failing tests** (`use Tymeslot.DataCase, async: false`). Setup: an organiser, an Outlook `calendar_integration`, a meeting `status: "confirmed"`, `calendar_sync_status: "externally_modified"`, `provider_event_id: "evt-1"`, start one day out; a `provider_calendar_event` on that integration with `provider_event_id: "evt-1"` at start + 2 h, end + 2 h, `start_at` carrying microseconds. Email mocks via `TestMocks.setup_email_mocks()`.
  - `"offers the event's time, to the second"`: `{:ok, %{start_time: s, end_time: e}}`, `s == DateTime.truncate(event.start_at, :second)`, same for `e`.
  - `"refuses …"`, one test per refusal, each changing one thing: flag `nil` or dismissed → `:not_flagged`; a `group_meeting` → `:group_meeting`; `status: "awaiting_approval"` → `:not_confirmed`; a queued `CalendarJobs.schedule_job(meeting, "update")` → `:calendar_write_pending`; no cache row → `:event_not_found`; `all_day: true` → `:all_day`; `end_at` equal to `start_at` → `:invalid_times`; cache times equal to the meeting's → `:unchanged`; cache start in the past → `:in_past`.
  - `"offers lists only the movable meetings"`: two meetings, one movable; `Map.keys(CalendarMove.offers([a, b])) == [a.id]`.
  - `"moves the booking and clears the flag"`: `{:ok, moved} = CalendarMove.move(meeting.id, user.id)`; `moved.start_time == offer.start_time`; `moved.calendar_sync_status == nil`.
  - `"uses the cached time at the moment of the move"`: take an offer, then move the cache row another hour, `move/2`, assert the later time.
  - `"a second move is refused"`: second `move/2` returns `{:error, :not_flagged}`.
  - `"refuses another organiser's meeting"`: `move(meeting.id, other_user.id) == {:error, :not_found}` and the meeting is unchanged.
- [ ] **Step 2: Run** `MIX_TEST test/tymeslot/meetings/calendar_move_test.exs`. Expected: all fail (`UndefinedFunctionError`).
- [ ] **Step 3: Implement** the module (`@moduledoc` naming the spec and why each refusal exists) and the three delegates.
- [ ] **Step 4: Run** the file. Expected: all pass.
- [ ] **Step 5: Commit** `feat(meetings): offer and perform a move to a calendar event's new time`.

### Task 5: The card button and its confirmation

**Files:**
- Create: `lib/tymeslot_web/live/dashboard/bookings_management/calendar_move.ex` (`TymeslotWeb.Dashboard.BookingsManagement.CalendarMove`, handler bodies, mirroring `BookingsManagement.RescheduleRequest`)
- Create: `lib/tymeslot_web/live/dashboard/bookings_management/calendar_move_modal.ex` (mirroring `RescheduleRequestModal`, built on the core modal)
- Modify: `lib/tymeslot_web/live/dashboard/bookings_management_component.ex` (mount `calendar_move: false` modal and `:move_offers` assign `%{}`; merge `Meetings.calendar_move_offers(page.items)` in `load_meetings/1` and in `load_more`; three thin `handle_event` clauses: `"show_calendar_move_modal"`, `"hide_calendar_move_modal"`, `"confirm_calendar_move"`)
- Modify: `lib/tymeslot_web/live/dashboard/bookings_management/modals.ex` (render the new modal)
- Modify: `lib/tymeslot_web/components/dashboard/meetings/meeting_list_components.ex` (`attr :move_offers, :map, default: %{}`; pass `move_offer={@move_offers[meeting.id]}`)
- Modify: `lib/tymeslot_web/components/dashboard/meetings/meeting_card.ex` (`attr :move_offer, :map, default: nil`; in `calendar_sync_banner/1`, when set, a button `phx-click="show_calendar_move_modal"` `phx-value-id={@meeting.id}` beside Dismiss)
- Modify: `priv/gettext/*.pot`, `priv/gettext/<locale>/LC_MESSAGES/dashboard_bookings.po`
- Create: `test/tymeslot_web/live/dashboard/bookings_management/calendar_move_test.exs`

**Interfaces:**
- Consumes: `Meetings.calendar_move_offer/1`, `Meetings.calendar_move_offers/1`, `Meetings.move_to_calendar_time/2` (Task 4); `RateLimiter.check_dashboard_reschedule_rate_limit/1` on confirm.
- Produces: modal data `%{meeting: MeetingSchema.t(), offer: offer()}` under `ModalHook` key `:calendar_move`.

Copy (domain `dashboard_bookings`; `%{time}` is the offer's start in the host's timezone and time format, through the formatting the card already uses for a meeting's start):
- button: `"Move booking to %{time}"`
- modal title: `"Move booking to the new time"`
- modal body: `"Your calendar now has this meeting at %{time}. Tymeslot will move the booking there, reschedule its reminders and email %{attendee_name} and any guests the new time."`
- confirm button: `"Move booking"`
- success flash: `"Booking moved to %{time}"`
- refusal flash for `:calendar_write_pending`: `"Tymeslot is still updating your calendar for this booking. Please try again in a moment."`
- refusal flash for every other reason: `"This booking can no longer be moved to its calendar time."`

- [ ] **Step 1: Write the failing tests** (LiveView, signed-in organiser through the existing dashboard test helpers, a movable meeting as in Task 4's setup, the meetings page route the existing `bookings_management_test.exs` uses):
  - `"a movable flagged booking offers its calendar time"`: card shows `"Move booking to"` with the formatted time, and `Dismiss`.
  - `"a flagged booking without a cached event offers only Dismiss"`: no `show_calendar_move_modal` element.
  - `"confirming moves the booking and clears the warning"`: click the button, modal shows the time, click `"Move booking"`; the meeting's `start_time` equals the cached start, flash `"Booking moved to"`, no `calendar_sync_banner` for that meeting.
  - `"the modal shows the time the calendar has when it opens"`: render, move the cache row an hour, click the button; modal shows the later time.
  - `"another organiser's meeting cannot be moved"`: `render_click(view, "show_calendar_move_modal", %{"id" => foreign.id})` and `"confirm_calendar_move"`: foreign meeting unchanged.
- [ ] **Step 2: Run** `MIX_TEST test/tymeslot_web/live/dashboard/bookings_management/calendar_move_test.exs`. Expected: all fail.
- [ ] **Step 3: Implement** the files above. `show` takes a fresh `Meetings.calendar_move_offer/1` for the organiser's meeting and opens the modal or flashes the refusal; `confirm` rate-limits, calls `Meetings.move_to_calendar_time/2`, flashes, reloads the list and hides the modal.
- [ ] **Step 4: Translate.** `MIX_DEV gettext.extract --merge`, fill the new `msgstr`s in `cs de fr it pl pt uk` per the glossaries, then `MIX_DEV gettext.merge priv/gettext --locale <locale>` for each (expect `0 new, 0 removed`).
- [ ] **Step 5: Run** the new file, `test/tymeslot_web/live/dashboard` and `test/tymeslot_web/gettext_completeness_test.exs`; `MIX_DEV credo --strict` and the xref gate. Expected: all pass, credo clean, xref ≤ 26.
- [ ] **Step 6: Commit** `feat(dashboard): move a flagged booking to its calendar event's new time`.

### Task 6: Point the host's email at the button

**Files:**
- Modify: `lib/tymeslot/emails/templates/external_booking_change.ex` (`:modified`, non-group only: the action button links to `UrlBuilder.build_url("/dashboard/meetings")`, already bound as `dashboard_url`; the HTML and text explanation use the new copy below; group and `:deleted` unchanged)
- Modify: `priv/gettext/*.pot`, `priv/gettext/<locale>/LC_MESSAGES/emails_booking.po`
- Test: `test/tymeslot/emails/templates/external_booking_change_test.exs`

Copy (domain `emails_booking`, replacing the non-group modified explanation):
`"This meeting was <strong>rescheduled in your external calendar</strong>. Tymeslot still shows the original time above. To move the booking to the new time, open it in your dashboard and choose <strong>Move booking</strong>: Tymeslot then reschedules its reminders and emails the attendee the new time."`
(The text body uses the same sentence without the tags, through the template's existing text helper.)

- [ ] **Step 1: Write the failing tests:** `"a rescheduled one-to-one meeting points to the dashboard's Move booking"`: HTML contains `"Move booking"` and an `href` ending in `"/dashboard/meetings"`; text body contains `"Move booking"`. `"a rescheduled group meeting keeps its own wording"`: no `"Move booking"`. `"a deleted meeting is unchanged"`: no `"Move booking"`.
- [ ] **Step 2: Run** `MIX_TEST test/tymeslot/emails/templates/external_booking_change_test.exs`. Expected: the first fails, the other two pass.
- [ ] **Step 3: Implement** the template change.
- [ ] **Step 4: Translate** as in Task 5 Step 4, for `emails_booking.po`; the replaced msgid's old translations are removed by the merge.
- [ ] **Step 5: Run** the file and the completeness test. Expected: pass.
- [ ] **Step 6: Commit** `feat(emails): point the external-change email at moving the booking`.

### Task 7: Whole-branch verification

- [ ] **Step 1:** `MIX_DEV` for `format --check-formatted`, `compile --warnings-as-errors`, `credo --strict`, `gettext.check`, `xref graph --label compile-connected --fail-above 26`; `MIX_TEST` with no paths (full suite, about 4 minutes, run in the background). Expected: gates clean; suite green apart from the two Monday-only `TimezoneChangeAvailabilityTest` failures.
- [ ] **Step 2:** Mark the spec `**Status:** implemented on merge-upstream-1.26.0` and commit `docs(meetings): mark the calendar-time move implemented`.
