# Booking pages: several start pages per host

**Status:** approved design, not yet implemented
**Date:** 2026-10-09
**Branch:** `feature/booking-pages`
**Fork:** `automaze-me/tymeslot` (private use; not currently targeted at upstream)

## Problem

The host serves different audiences (for example einfachISO clients and
automaze.me clients) from one Tymeslot account. Today the account has exactly
one public start page, `/<username>`, and everything on it is profile-wide: the
theme and its colours (`profiles.booking_theme`, `theme_customizations` keyed by
profile and theme), the heading, greeting and instruction
(`profiles.booking_*`, from upstream #91), and the list of meeting types (every
active type not marked unlisted).

Each audience needs its own start page: its own address, its own look, its own
texts and its own selection of meeting types. A meeting type must also be
hideable from every page at once while staying bookable through its direct
link.

Upstream has nothing comparable (searched 2026-10-09: issues, PRs and
discussions in all states). The closest pieces are the "Unlisted" switch
(upstream's reimplementation of the closed PR #54) and the booking texts of
issue #91, both of which this design builds on.

## Decisions taken in review

- Pages exist for **different audiences**: each has its own texts, its own
  theme and colours, and its own meeting types. Name, photo and language stay
  shared.
- An extra page has its **own top-level address** (`/einfachiso`), working like
  a second username, and the whole booking flow stays under it.
- **Every page picks its meeting types**, `/<username>` included. A type on no
  page is hidden from all of them and stays bookable by its direct link.
- **Approach A**: `/<username>` stays on the profile; extra pages are layered
  on top in a new table. Rejected: moving all page settings off the profile
  (cleaner, but rewrites upstream's theme and booking-text code and makes every
  future merge collide), and modelling pages as extra profiles (a profile also
  carries timezone, schedules, limits, travel and time off).

## Non-goals

- Per-page name, photo or default language.
- Per-page booking rules. Availability, buffers, notice, limits, schedules and
  travel stay per meeting type and profile; a page only decides what is listed
  and how it looks.
- Per-page meeting type order. Pages list types in the existing global
  `sort_order`.
- Redirects from a page's old address after it is changed or deleted.
- Moving polls under pages. Poll links stay `/<username>/poll/<token>`.
- Pages in demo mode.

## Design constraint particular to this fork

The fork tracks upstream closely, and the 1.23.0 merge showed what a wide
diff costs. The design therefore keeps upstream's tables and code paths where
they are: the profile's own page fields stay authoritative for
`/<username>`, and every change to an upstream module is a narrow hook
(resolve a page, read the page's value instead of the profile's) rather than a
restructuring. New behaviour lives in new modules.

## Data model

### `booking_pages`

| Column | Type | Notes |
| --- | --- | --- |
| `id` | bigint | |
| `profile_id` | references `profiles`, `on_delete: :delete_all` | |
| `slug` | string, not null | The address. Lowercase. Unique index. |
| `name` | string, not null | Dashboard label, e.g. "einfachISO". |
| `booking_theme` | string, not null | Theme id, as `profiles.booking_theme`. |
| `booking_text_enabled` | boolean, default false | As on the profile. |
| `booking_heading` | string | As on the profile, same limits. |
| `booking_greeting` | string | As on the profile, same limits. |
| `booking_instruction` | string | As on the profile, same limits. |
| timestamps | | |

A profile may hold at most 10 pages (`BookingPages.max_pages/0`), enforced in
the context, in the manner of `Schedules.max_schedules/0`.

### `booking_page_meeting_types`

`booking_page_id` (references `booking_pages`, `on_delete: :delete_all`),
`meeting_type_id` (references `meeting_types`, `on_delete: :delete_all`),
unique index on the pair. A row means "listed on that extra page".

### Membership of `/<username>`

Unchanged storage: `meeting_types.is_private == false` means "listed on
`/<username>`". The dashboard presents it as "Show on /<username>". A type is
**hidden from all pages** when `is_private` is true and it has no join rows.
Direct links keep their current rule: any active, not paused type is bookable
by its effective slug.

### `theme_customizations.booking_page_id`

New nullable column referencing `booking_pages`, `on_delete: :delete_all`.
Existing rows keep `NULL` and remain the `/<username>` page's customisations.
The unique index on `(profile_id, theme_id)` becomes partial
(`WHERE booking_page_id IS NULL`), and a second unique index covers
`(booking_page_id, theme_id)`.

### `meetings.booking_page_id`

New nullable column referencing `booking_pages`, `on_delete: :nilify_all`.
Records which page a booking came through; `NULL` means `/<username>` or no
page (direct link under the username, quick add, API).

The migration changes no existing row's meaning: after it, `/<username>`
shows exactly what it showed before and no extra pages exist.

## Address namespace

A page address follows `UsernameValidator.validate/1` and is stored
lowercase. Usernames, page addresses and `Profiles.reserved_paths/0` share one
namespace:

- Creating or renaming a page rejects an address that is reserved, is any
  profile's username, or is another page's address (the last one is also the
  unique index).
- `Profiles.username_status/2` and the profile changeset reject a username
  that is any page's address.

The two tables cannot share a database constraint, so a simultaneous
username and page save could still collide. Resolution therefore always tries
the username first: a page can never take over another host's start page.

## Address resolution

A new resolver, `BookingPages.resolve(segment)`, returns
`{:ok, %{profile: profile, page: page_or_nil}}` or `:error`: the profile with
that username and `page: nil`, else the profile owning the page with that
address and the page, else `:error`.

It is reached through the lookup the public entry points already share,
`Profiles.get_profile_by_username/1`, which falls back to it when no username
matches, and through `Profiles.resolve_organizer_context/1`. That covers:

- `Profiles.resolve_organizer_context/1` (reached through `Demo` and
  `OrganizerHelpers.handle_username_resolution/2` from `Themes.Core.Dispatcher`
  and `Themes.Shared.LiveHelpers`), which also puts `:booking_page` into the
  organiser context;
- `TymeslotWeb.Hooks.ThemeHook`;
- `TymeslotWeb.Hooks.EmbedAuthHook`;
- `TymeslotWeb.Plugs.SecurityHeadersPlug` (frame-ancestors from the profile's
  allowed embed domains);
- `TymeslotWeb.Hooks.PageViewHook`;
- `TymeslotWeb.MeetingCalendarController` (`.ics` download).

Callers that only need the owner use `profile` and behave exactly as before.
The demo provider resolves usernames only. None of these lookups is cached
today, so renaming or deleting a page takes effect on the next request.

## Public flow

**Start page `/<page>`.** Lists `BookingPages.list_meeting_types(page)`: the
page's join rows, active and not paused (`GroupAccess.reject_paused/1`), in
`sort_order`. Texts come from the page (`BookingText` reads a page as it reads
a profile), theme and colours from the page (see below). Display name, avatar,
page title and language behave as on `/<username>`. The empty state is the
existing one.

**Flow under the page.** `/<page>/<slug>`, `/<page>/<slug>/book` and
`/<page>/thank-you` are the existing routes with a page address in the
`:username` segment. Every in-flow link is built from that segment
(`Themes.Shared.PathHandlers`, `LiveHelpers`), so the visitor stays under the
page and "back" returns to it. `/<page>/<slug>` resolves any active, not
paused meeting type of the owner, listed on that page or not, as
`/<username>/<slug>` does today.

**Bookings.** A booking made under a page address carries the page id through
`Bookings.BuildParams` (beside the UTM fields) into `meetings.booking_page_id`.
If the page has been deleted by the time the booking is saved, the id is
dropped and the booking succeeds.

**Emails and managing a booking.** Cancel and reschedule links stay
`/<username>/meeting/<uid>/…`, built by `Bookings.Policy` as today, so a page
rename or deletion never breaks a link already sent. On those routes,
`ThemeHook` and the theme context take the theme and colours from the
meeting's page when it still exists, otherwise from the profile. The
cancellation email's "Book Another Time" link (`AppointmentBuilder`,
`UrlBuilder.booking_url/1`) points to the meeting's page address when the page
still exists.

**Embeds.** The snippet's `data-username` accepts a page address through the
resolver. Allowed embed domains stay one list per profile.

## Theme resolution

`ThemeHook` takes the theme id from `page.booking_theme` when the resolver
returns a page, otherwise from the profile, as now. `Themes.Core.Context`
loads customisations for `(page, theme)` when there is a page and for
`(profile, theme)` with `booking_page_id IS NULL` otherwise, falling back to
`ThemeCustomizations.get_defaults/1` as today.

A new page starts with the `/<username>` page's theme and copies of its
customisation rows: colour scheme, palette seed and gradient background.
Uploaded image and video backgrounds are not copied; those rows fall back to
the theme's default background. Sharing one file between pages would let
deleting one page remove another's background.

## Dashboard

**Theme screen (`/dashboard/theme`).** A page switcher at the top, modelled on
the Availability screen's schedule switcher: `/<username>` first (cannot be
deleted), each extra page, then "New page" (disabled at the cap). Everything
below applies to the selected page: the theme picker, the colour and
background editor (`ThemeCustomizationComponent`) and the booking-texts form
(`BookingTextForm`). Below the editors:

- **Address**: the full link with copy and open buttons; editable, with the
  name, for extra pages. Changing it warns that the old address stops working
  immediately and that links in emails already sent are unaffected.
- **Meeting types on this page**: a checklist of all the host's meeting types.
  On `/<username>` it writes `is_private`; on an extra page, join rows.
- **Delete page** (extra pages), confirmed with `Modal.confirm_modal`. The
  dialog says bookings made through the page keep working with the
  `/<username>` look, and that its colours and uploaded backgrounds are
  removed.

**New page dialog.** Name and address; the address is suggested from the
name and checked as the host types (format, reserved, username, other page).

**Meeting type form, Visibility section.** The switch "Hide from public
booking page" becomes one switch per page ("Show on /<username>", "Show on
/<page>", …). With all off, a note says the type is on no page and bookable
only through its direct link. The section stays edit-only, and a new type
starts on `/<username>` only, as today.

**Meeting type cards.** The "Unlisted" badge stays for a type on no page.
Once extra pages exist, each card shows chips naming the pages it is on.

**Embed screen.** A page picker feeding the generated snippet and the live
preview.

**Profile settings.** The username check rejects page addresses (see Address
namespace).

## Error handling and edge cases

- Page validation errors (format, reserved, taken, cap) surface on the form
  fields; the cap also refuses in the context.
- Deleting a page removes its join rows, customisation rows and uploaded
  background files (`ThemeCustomizations.FileLifecycle`); its meetings keep
  their links with `booking_page_id` cleared.
- Deleting a meeting type removes its join rows.
- A visitor on a page that is deleted mid-flow can finish booking; the
  booking records no page. The next navigation to the page's address is a 404.
- An unknown address is a 404, as today.

## Testing

- **Domain** (`BookingPages`): create, rename, delete; the cap; address
  validation in both directions, including reserved paths; the resolver
  (username first, page second, unknown is `:error`); per-page listing,
  hidden-from-all, inactive and paused types left out; per-page customisation
  uniqueness and the copy on create, uploads excluded.
- **Migration**: existing customisation rows stay the profile's; the partial
  and page unique indexes hold.
- **Public flow**: `/<page>` shows the page's texts, theme, colours and types;
  in-flow links and "back" stay under the page; a booking records its page;
  cancel and reschedule show the page's theme and fall back after deletion;
  the cancellation email links to the page; embed auth, security headers and
  page views accept a page address; unknown addresses 404.
- **Dashboard**: the page switcher; create, rename, delete; the checklist and
  the meeting type form's switches; the embed picker; a username change
  blocked by a page address.
- **Translations**: every new string translated in all non-English locales
  (`GettextCompletenessTest`).
- **Gates**: `compile --warnings-as-errors` (dev and test), `format
  --check-formatted`, `credo --strict` (module-size caps), `gettext.extract
  --check-up-to-date`, full `mix test`.

## File inventory

New:

- `priv/repo/migrations/*_create_booking_pages.exs`: both tables, the two new
  columns, the customisation index change.
- `lib/tymeslot/booking_pages.ex`: context (CRUD, cap, membership, resolver,
  listing, customisation copy).
- `lib/tymeslot/booking_pages/booking_page_schema.ex`,
  `booking_page_meeting_type_schema.ex`, `booking_page_queries.ex`.
- Dashboard: a page switcher, a page settings section (address, checklist,
  delete), a new-page dialog and a delete dialog under
  `lib/tymeslot_web/live/dashboard/theme_settings/`.

Changed (narrow hooks):

- `lib/tymeslot/profiles.ex`, `profiles/organizer_context.ex`,
  `profiles/profile_schema.ex`: resolver use, organiser context page,
  username/page namespace check.
- `lib/tymeslot/demo/behaviour.ex`, `demo/no_op.ex`: resolver passthrough.
- `lib/tymeslot/theme_customizations.ex`, `theme_customization_schema.ex`,
  `theme_customization_queries.ex`: per-page rows.
- `lib/tymeslot/meetings/meeting_schema.ex`, `bookings/build_params.ex`,
  `bookings/policy.ex`, `bookings/create.ex`: `booking_page_id` beside the
  UTM fields. `Bookings.Policy` is at 649 of credo's 650-line cap, so the plan
  has to make room there (for example by moving the attribution fields into a
  helper) rather than add to it.
- `lib/tymeslot/emails/appointment_builder.ex`: page-aware booking URL.
- `lib/tymeslot_web/themes/core/context.ex`,
  `themes/shared/customization/helpers.ex`: a page's colours. The theme hook,
  embed check, security headers, page views and `.ics` download need no
  change: they all resolve through `Profiles.get_profile_by_username/1`.
- `lib/tymeslot_web/themes/shared/booking_text.ex`: read a page or a profile.
- `lib/tymeslot_web/live/dashboard/theme_settings_component.ex`,
  `theme_settings/booking_text_form.ex`,
  `theme_settings/theme_customization_component.ex`: scoped to the selected
  page.
- `lib/tymeslot_web/live/dashboard/meeting_settings/meeting_type_form/visibility_section.ex`,
  `meeting_settings/card.ex`, `service_settings_component.ex`: per-page
  switches and chips.
- `lib/tymeslot_web/live/dashboard/embed_settings_component.ex` and
  `embed_settings/helpers.ex`: page picker.
- `priv/gettext/**`: new strings, all locales.

## Definition of done

- A host can create up to 10 extra pages, each with its own address, theme,
  colours, texts and meeting types, and edit or delete them.
- `/<page>` and its whole booking flow render with the page's look and list
  only its types; `/<username>` behaves exactly as before.
- A meeting type can be shown on any combination of pages or on none, and a
  type on none stays bookable by direct link.
- Bookings record their page; cancel and reschedule screens and the
  cancellation email follow it, and nothing breaks when a page is renamed or
  deleted.
- All gates above pass, with the full suite at the merge baseline (19676/19677,
  the known `SeatLockedEventsTest` load flake aside).
