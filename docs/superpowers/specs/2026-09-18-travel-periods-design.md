# Travel periods: date-scoped timezone and hours

**Status:** approved design, not yet implemented
**Date:** 2026-09-18
**Branch:** `feature/travel-periods`
**Fork:** `automaze-me/tymeslot` (private use; not currently targeted at upstream)

## Problem

The host travels to Europe regularly and needs European hours, in a European
zone, for those date ranges only. Tymeslot currently permits exactly one
timezone per account: `profiles` is unique per `user_id`, the `timezone` column
lives there, `availability_schedules` has no timezone column, and
`owner_timezone` resolves once per request as
`organizer_profile.timezone || Profiles.get_default_timezone()`.

Named schedules already let hours differ per meeting type, but every schedule
shares the one clock. Expressing a trip today means hand-shifting wall-clock
times into the home zone with a `custom_hours` override per date, and the
dashboard and emails still read in the home zone throughout.

The requirement that constrains the design: **a booking made while the host is
away, for a date after the host returns, must be offered home availability.**
Resolution therefore keys off the *slot's* date, never today's.

## Non-goals

- Recurring or repeating trips. Each trip is entered individually.
- Breaks within trip days. `weekly_availability` has them; trip days do not yet.
  The table shape admits them later without a migration to existing columns.
- Per-trip scheduling policy. Buffer, notice and horizon always come from the
  meeting type's resolved schedule.
- Blocking travel days. A flight is a timed event on a synced calendar and
  already blocks those hours through ordinary conflict checking; a second
  mechanism would duplicate it.
- Multiple profiles per account, or root-level booking paths.

## Design constraint particular to this fork

Upstream ships releases regularly and the availability engine is actively
developed. Every *existing* file this feature edits is a permanent rebase
conflict surface, so the design deliberately maximises new files and keeps each
edit to an existing file small and local. The eleven touched files are
inventoried at the end.

## Data model

Two new tables, created in a single generated migration. Migrations are
generated with `mix ecto.gen.migration`, never written by hand, per
`CONTRIBUTING.md`.

### `travel_periods`

| Column | Type | Notes |
| --- | --- | --- |
| `profile_id` | references(:profiles) | `on_delete: :delete_all` |
| `label` | string | not null, e.g. "Berlin, spring" |
| `start_date` | date | not null, inclusive |
| `end_date` | date | not null, inclusive |
| `timezone` | string | not null, IANA id |

- Check constraint: `end_date >= start_date`.
- Index on `(profile_id, start_date, end_date)` for the window lookup.
- `timezone` validated with `Tymeslot.Timezones.valid?/1`, the same validator
  `ProfileSchema` already uses.

**Non-overlap** is enforced in the changeset, not the database. The rigorous
form is an exclusion constraint —
`EXCLUDE USING gist (profile_id WITH =, daterange(start_date, end_date, '[]') WITH &&)` —
but that needs the `btree_gist` extension, which some managed Postgres will not
grant a non-superuser, and Core ships to self-hosters. The race window is one
user editing their own trips, so a changeset check reading through
`TravelPeriodQueries.overlapping/4` is the right trade.

### `travel_period_days`

| Column | Type | Notes |
| --- | --- | --- |
| `travel_period_id` | references(:travel_periods) | `on_delete: :delete_all` |
| `day_of_week` | integer | 1 (Monday) – 7 |
| `is_available` | boolean | default false |
| `start_time` | time | |
| `end_time` | time | |

Unique on `(travel_period_id, day_of_week)`. Deliberately mirrors
`weekly_availability` so the editor components and the day-shape logic are
shared rather than parallel.

### New modules

Following the naming of the existing availability domain:

- `Tymeslot.Availability.TravelPeriodSchema`
- `Tymeslot.Availability.TravelPeriodDaySchema`
- `Tymeslot.Availability.TravelPeriodQueries` — every `Repo` call lives here
- `Tymeslot.Availability.Travel` — the public context, sibling of `Schedules`
- `Tymeslot.Availability.OwnerFrame` — the single answer to "which zone and
  which hours are in effect on date D". Named for the "owner frame" vocabulary
  `TimeSlots` already uses.

## Resolution rule

`OwnerFrame.for_date(date, owner_timezone, config)` returns
`%{timezone: String.t(), day: BusinessHours.day_availability(), source: :travel | :schedule}`.

| | Trip covers the date | Otherwise |
| --- | --- | --- |
| Zone | `trip.timezone` | `owner_timezone` (the home zone) |
| Weekly hours | trip's day row for that weekday | schedule's weekly row |
| Date overrides | meeting type's resolved schedule | meeting type's resolved schedule |
| Policy | meeting type's resolved schedule | meeting type's resolved schedule |

`day` is returned in the existing `BusinessHours.day_availability()` shape, with
`breaks: []` for trip days. This is what keeps the `BusinessHours` edit
surgical: only the source of the zone and the day changes; every line
downstream of that, including the override lookup and the window construction,
is untouched.

Two consequences worth stating explicitly:

- **A date override still wins inside a trip.** An "unavailable, 20 Mar"
  holiday holds whether or not a trip covers it, and its wall-clock times are
  read in whichever zone applies to that date. The cost is that "unavailable
  only because I am travelling" cannot be expressed as trip data.
- **`owner_timezone` changes meaning** from "the effective zone" to "the home
  zone fallback". The key is *not* renamed: a rename across every call site is
  the worst possible diff on a fork that rebases indefinitely. The shift is
  documented at the `availability_config` typedoc and in `OwnerFrame`.

DST needs no special handling. Wall-clock times resolve against a real date and
zone through the existing `resolve_wall_time/3`, whose policy is already
stated: ambiguous times (fall-back) anchor to the first occurrence, gaps
(spring-forward) snap to just after. A trip straddling a DST boundary is
therefore correct per date, including a late-March trip that crosses both the
EU switch (last Sunday) and the US one (second Sunday).

## Engine threading

The correctness hazard is that two different builders assemble the config:

- Submit path: `Tymeslot.Bookings.Policy.scheduling_config/2` sets
  `:owner_timezone` from `settings.timezone` (`policy.ex:59`).
- Display path: `TymeslotWeb.Live.Scheduling.AvailabilityHelpers.schedule_config/4`
  does not set it; the caller passes it separately.

If only one learned about trips, the booking page would offer slots that
`ScheduleCheck.validate_slot_on_schedule/6` then refuses as `:slot_not_offered`.
`policy.ex` already documents the remedy it uses for exactly this hazard:
`slot_interval_minutes/1` is "the single resolver for this value, shared by
`scheduling_config/2` here and by `AvailabilityHelpers`, so the display path and
the submit path cannot disagree about the interval."

This design follows that precedent:

1. `Travel.for_window(profile_id, first_date, last_date)` is the single trip
   resolver, called by **both** builders, placing the trips in
   `config[:travel_periods]`. The display path passes the window it is already
   prefetching for; the submit path, which concerns exactly one slot, passes
   `(date, date)`. `Policy.scheduling_config/2` holds an `organizer_user_id`
   rather than a profile id, and already calls
   `Profiles.get_profile_settings/1` — the profile id comes from there, so no
   additional query is introduced.
2. `OwnerFrame.for_date/3` is called **inside**
   `BusinessHours.get_business_hours_in_timezone/5`. Because `offers_slot/6`,
   `available_slots/6`, `range_availability/6` and `get_calendar_days/5` all
   resolve a day's window through that one function, every path inherits trips
   structurally rather than by each remembering to.

Prefetching: `Calculate.prefetch_schedule_data/4` returns early when
`schedule_id` is `nil`, and trips are profile-scoped rather than
schedule-scoped, so trip loading cannot live inside that guard. A sibling
`prefetch_travel_periods/4`, keyed by `profile_id`, loads the window's trips in
one query alongside the existing weekly/override prefetch.

Caching: `AvailabilityCache.invalidate_for_user/1` on every trip create, update
and delete.

## Display resolution

"What time is it for me now" and "when will this meeting be for me" are
different questions and get different dates, through one resolver:
`Profiles.timezone_on(profile, date)` — the trip covering that date, else the
profile zone. Unlike the availability path, these callers hold no
`availability_config`, so this resolver reads through `TravelPeriodQueries`
directly rather than expecting prefetched trips.

| Surface | Date passed |
| --- | --- |
| Dashboard calendar grid | today |
| Desktop reminder feed | today |
| Host-facing meeting emails | the meeting's own date |

Passing the meeting's date for emails means a February booking for a March
Berlin meeting is confirmed as 15:00 CET — the zone the host will be in when it
happens — rather than 09:00 EST.

Unaffected: booker-facing pages (bookers always see their own zone), the
free/busy feed and ICS generation (both publish instants), and every stored
timestamp (`utc_datetime` throughout).

A dashboard banner names the active trip's zone whenever a trip covers today.
Without it the grid silently shifts by hours and reads as a bug.

## UI

A "Travel" section on the availability page (`schedule_settings_component.ex`),
below the existing schedule tab strip:

- Trips listed with label, date range and zone, plus add / edit / delete.
- The editor reuses the existing `TimezoneDropdown` component and the 7-day
  weekly-hours grid from the schedule editor.
- Data loads in `handle_params/3`, never `mount/3`, per the house rule.
- HEEx comments only (`<%!-- --%>`).

No cap on the number of trips. The 5-schedule cap exists because schedules
render as a tab strip; a trip list has no such constraint.

## Testing

Every test module declares `@moduletag :availability` plus the applicable type
tag from `test/support/tag_taxonomy.ex` (`:unit`, `:queries`, `:schema`,
`:live`). The cases that carry the design:

1. A slot on a post-return date, requested while a trip is active, resolves to
   the home zone and the normal schedule. *The headline requirement.*
2. A slot on a date inside a trip resolves to the trip zone and trip hours.
3. `offers_slot/6` agrees with `available_slots/6` for a trip date **and** for a
   post-return date. This is the test that justifies the shared resolver.
4. A trip straddling a DST boundary yields correct wall-clock hours on both
   sides.
5. A date override still wins for a date inside a trip.
6. Buffer, notice and horizon still come from the meeting type's schedule
   during a trip.
7. Overlapping trips are rejected by the changeset.
8. With zero trips, behaviour is identical to current behaviour.

## File inventory

New (no rebase conflict surface): the five modules above, one migration, the
trip-editor components, and their tests.

Edited, load-bearing four:

- `lib/tymeslot/availability/business_hours.ex` — resolve the frame per date
- `lib/tymeslot/availability/calculate.ex` — `prefetch_travel_periods/4`, typedoc
- `lib/tymeslot/bookings/policy.ex` — trips into `scheduling_config/2`
- `lib/tymeslot_web/live/scheduling/availability_helpers.ex` — trips into
  `schedule_config/4`

Edited, display and UI:

- `lib/tymeslot/profiles/timezone.ex` — `timezone_on/2`
- `lib/tymeslot/emails/appointment_builder.ex`
- `lib/tymeslot/emails/email_service/calendar_emails.ex`
- `lib/tymeslot_web/live/dashboard/calendar_grid/*` — grid zone assign
- `lib/tymeslot_web/live/dashboard/calendar_grid/desktop_reminder_feed.ex`
- `lib/tymeslot_web/live/dashboard/schedule_settings_component.ex`

## Definition of done

Per `CONTRIBUTING.md`: `mix test` with 0 failures, `mix credo --strict` clean,
`mix dialyzer` with no warnings, `mix format --check-formatted`.
