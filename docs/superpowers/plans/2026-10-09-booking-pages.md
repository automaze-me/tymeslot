# Booking Pages Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a host run several public start pages (`/einfachiso`, `/automaze`), each with its own address, theme, colours, texts and meeting types, beside the existing `/<username>` page.

**Architecture:** Extra pages live in a new `booking_pages` table; the `/<username>` page stays on the profile. A page address resolves, at the one lookup every public entry point already uses (`Profiles.get_profile_by_username/1`), to the owner's profile with the page's theme and texts laid over it plus a virtual `booking_page` field, so theme selection, booking texts, embed checks, security headers, analytics and `.ics` downloads work unchanged. Only colour loading (a per-page "scope" in `ThemeCustomizations`), the start page's meeting type list, bookings (which record their page) and the dashboard know about pages explicitly.

**Tech Stack:** Elixir 1.20 / Phoenix LiveView 1.2 / Ecto + PostgreSQL 17, ExMachina factories, Gettext.

**Spec:** `docs/superpowers/specs/2026-10-09-booking-pages-design.md`

## Global Constraints

- Work on branch `feature/booking-pages`. Commit after every task; messages in the repo's conventional style (`feat(booking-pages): …`, `test(…)`, `fix(…)`), **without** any `Co-Authored-By` trailer or "Generated with Claude Code" footer.
- The host has no Elixir. Every `mix` command runs in Docker against the stopped test database container. Start it once per session with `docker start tymeslot-test-pg`; stop it at the end with `docker stop tymeslot-test-pg`. Run mix as (replace `<ARGS>`; use `-e MIX_ENV=dev` for `credo`, `format`, `gettext.*`, `excellent_migrations.*`):

  ```bash
  mkdir -p "$HOME/.cache/tymeslot-mixhome"
  docker run --rm --user 1000:1000 --network container:tymeslot-test-pg \
    -v "$HOME/tymeslot":/app -v "$HOME/.cache/tymeslot-mixhome":/home/u \
    -e HOME=/home/u -e MIX_ENV=test -w /app tymeslot-dev:local \
    bash -c 'mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null && mix <ARGS>'
  ```

  In the steps below, "Run (mix): `test test/x_test.exs`" means that command with `<ARGS>` = `test test/x_test.exs`.
- At most **10** extra pages per profile (`BookingPages.max_pages/0`).
- A page address follows `UsernameValidator.validate/1`, is trimmed and stored lowercase, may not be in `Profiles.reserved_paths/0`, and shares one namespace with usernames in both directions. When a username and a page address collide anyway, the **username wins** at resolution.
- Credo `--strict` must stay clean: modules at most 650 lines (`CredoChecks.LargeModules`); `Repo.*` calls only in `*_queries.ex` and schema files; web modules (`lib/tymeslot_web/**`) never alias or call a `*Queries` module; every user-facing string goes through `dgettext/3` with a known domain (`dashboard_appearance`, `dashboard_meeting_form`, `dashboard_embed`, `errors` are the ones used here); flashes in live components go through `TymeslotWeb.Live.Shared.Flash`; every test module has a domain `@moduletag` (`:profiles`, `:themes`, `:scheduling`, `:bookings`, `:emails`, `:dashboard`, `:meeting_types`).
- `Bookings.Policy` is at 649 lines; this plan keeps it at or under 650.
- Every new string is translated in `cs`, `de`, `fr`, `it`, `pl`, `pt`, `uk` (English msgstrs stay empty) — the gettext completeness test fails otherwise. Task 13 carries the translations.
- Changes to upstream modules stay narrow hooks; new behaviour lives in new modules.

## Review Focus

1. **A page with no listable meeting types** (none ticked, or all inactive/paused) must show the start page's empty state, not fall back to `/<username>`'s types — `OrganizerContext.meeting_types_for_profile/1` currently refetches the profile's public types when the list is empty. Pinned in Task 6.
2. **A profile row and a page row for the same theme** must not crash profile-scope lookups: `ThemeCustomizationQueries.get_by_profile_and_theme/2` uses `Repo.get_by(profile_id:, theme_id:)`, which raises `Ecto.MultipleResultsError` once a page row exists. Pinned in Task 2.
3. **Saving booking texts on a page tab** must not write them onto the profile: the form receives the overlaid profile, and `Profiles.update_booking_text/2` would persist the page's texts into `profiles`. Pinned in Task 9.
4. **Selecting a theme on a page tab** must change only the page, and must never send the overlaid profile to `DashboardLive` as `{:profile_updated, …}` (the dashboard would adopt the page's look as the profile's). Pinned in Task 9.
5. **An address typed as `" EinfachISO "`** must be stored as `einfachiso` and collide with an existing `einfachiso` page or username, not create a second, differently-cased address. Pinned in Task 3.

---

## File Structure

New:

| File | Responsibility |
| --- | --- |
| `priv/repo/migrations/20261009120000_create_booking_pages.exs` | Both tables; `booking_page_id` on `theme_customizations` and `meetings`; customisation index swap. |
| `lib/tymeslot/booking_pages.ex` | Context: page CRUD, cap, address namespace, membership, resolution and overlay helpers. |
| `lib/tymeslot/booking_pages/booking_page_schema.ex` | Page schema and changesets. |
| `lib/tymeslot/booking_pages/booking_page_meeting_type_schema.ex` | Join row: a meeting type listed on a page. |
| `lib/tymeslot/booking_pages/booking_page_queries.ex` | All `Repo` access for pages and memberships. |
| `lib/tymeslot_web/live/dashboard/theme_settings/pages_component.ex` | Theme screen: page tabs and the new-page dialog. |
| `lib/tymeslot_web/live/dashboard/theme_settings/page_settings_component.ex` | Theme screen: the selected page's address, name, meeting type checklist and deletion. |
| `lib/tymeslot_web/live/dashboard/meeting_settings/page_visibility.ex` | Pure helpers turning pages + memberships into visibility rows and card chips. |

Changed (narrow hooks): `theme_customization_schema.ex`, `theme_customization_queries.ex`, `theme_customizations.ex`, `meeting_schema.ex`, `profile_schema.ex`, `profile_queries.ex`, `profiles.ex`, `organizer_context.ex`, `demo.ex`, `demo/behaviour.ex`, `demo/no_op.ex`, `themes/core/context.ex`, `themes/shared/customization/helpers.ex`, `themes/core/mount_helpers.ex`, `themes/shared/path_handlers.ex`, `booking_submission_handler_component.ex`, `bookings/create.ex`, `bookings/build_params.ex`, `bookings/policy.ex`, `emails/appointment_builder.ex`, `theme_settings_component.ex`, `theme_settings/booking_text_form.ex`, `theme_settings/theme_customization_component.ex`, `theme_settings/background_uploads.ex`, `helpers/theme_upload_helper.ex`, `theme_settings/theme_customization/components.ex`, `service_settings_component.ex`, `service_settings/component_view.ex`, `meeting_settings/meeting_type_form.ex`, `meeting_type_form/form_view.ex`, `meeting_type_form/visibility_section.ex`, `meeting_settings/meeting_types_list_component.ex`, `meeting_settings/card.ex`, `embed_settings_component.ex`, `test/support/factory.ex`, `priv/gettext/**`.

---

### Task 1: Tables, schemas and factories

**Files:**
- Create: `priv/repo/migrations/20261009120000_create_booking_pages.exs`
- Create: `lib/tymeslot/booking_pages/booking_page_schema.ex`
- Create: `lib/tymeslot/booking_pages/booking_page_meeting_type_schema.ex`
- Modify: `lib/tymeslot/theme_customizations/theme_customization_schema.ex`
- Modify: `lib/tymeslot/meetings/meeting_schema.ex` (field list ~line 305, cast list ~line 393, changeset ~line 524, `@type` ~line 101)
- Modify: `lib/tymeslot/profiles/profile_schema.ex` (virtual field ~line 84, `booking_text_changeset/2` spec ~line 156)
- Modify: `test/support/factory.ex`
- Test: `test/tymeslot/booking_pages/booking_page_schema_test.exs`

**Interfaces:**
- Produces: `Tymeslot.BookingPages.BookingPageSchema` with fields `profile_id, slug, name, booking_theme, booking_text_enabled, booking_heading, booking_greeting, booking_instruction`; `create_changeset/2`, `details_changeset/2`, `theme_changeset/2`, `name_max_length/0`.
- Produces: `Tymeslot.BookingPages.BookingPageMeetingTypeSchema` (`booking_page_id`, `meeting_type_id`), `changeset/2`.
- Produces: `ThemeCustomizationSchema.booking_page_id`, `MeetingSchema.booking_page_id`, `ProfileSchema.booking_page` (virtual, default `nil`).
- Produces: factories `:booking_page` (needs `profile:`), `:booking_page_meeting_type`.

- [ ] **Step 1: Write the failing schema test**

```elixir
# test/tymeslot/booking_pages/booking_page_schema_test.exs
defmodule Tymeslot.BookingPages.BookingPageSchemaTest do
  use Tymeslot.DataCase, async: true

  @moduletag :profiles
  @moduletag :unit

  import Tymeslot.Factory

  alias Tymeslot.BookingPages.BookingPageSchema
  alias Tymeslot.Repo
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema

  defp create(attrs) do
    BookingPageSchema.create_changeset(
      %BookingPageSchema{},
      Map.merge(%{profile_id: insert(:profile).id, booking_theme: "1"}, attrs)
    )
  end

  test "trims and lowercases the address" do
    changeset = create(%{name: " einfachISO ", slug: "  EinfachISO "})

    assert changeset.valid?
    assert Ecto.Changeset.get_change(changeset, :slug) == "einfachiso"
    assert Ecto.Changeset.get_change(changeset, :name) == "einfachISO"
  end

  test "refuses an address the username rules refuse" do
    refute create(%{name: "x", slug: "ab"}).valid?
    refute create(%{name: "x", slug: "has space"}).valid?
    refute create(%{name: "x", slug: "-leading"}).valid?
  end

  test "refuses a reserved address" do
    changeset = create(%{name: "Dash", slug: "dashboard"})

    assert {"is reserved", _opts} = changeset.errors[:slug]
  end

  test "refuses an unknown theme" do
    refute create(%{name: "x", slug: "fine-name", booking_theme: "99"}).valid?
  end

  test "the database refuses a second page with the same address in any case" do
    profile = insert(:profile)
    insert(:booking_page, profile: profile, slug: "einfachiso")

    {:error, changeset} =
      %BookingPageSchema{}
      |> BookingPageSchema.create_changeset(%{
        profile_id: profile.id,
        booking_theme: "1",
        name: "Again",
        slug: "EINFACHISO"
      })
      |> Repo.insert()

    assert {"has already been taken", _opts} = changeset.errors[:slug]
  end

  test "a profile row and a page row may share a theme" do
    profile = insert(:profile)
    page = insert(:booking_page, profile: profile)

    insert(:theme_customization, profile: profile, theme_id: "1")
    insert(:theme_customization, profile: profile, booking_page: page, theme_id: "1")

    assert Repo.aggregate(ThemeCustomizationSchema, :count) == 2
  end
end
```

- [ ] **Step 2: Run it to see it fail**

Run (mix): `test test/tymeslot/booking_pages/booking_page_schema_test.exs`
Expected: compilation error, `Tymeslot.BookingPages.BookingPageSchema` is undefined.

- [ ] **Step 3: Write the migration**

```elixir
# priv/repo/migrations/20261009120000_create_booking_pages.exs
defmodule Tymeslot.Repo.Migrations.CreateBookingPages do
  @moduledoc """
  Booking pages: extra public start pages of a profile, each at its own
  top-level address with its own theme, texts and meeting types, beside the
  profile's own page at `/<username>`.

  Adds `booking_pages` and `booking_page_meeting_types`, and a nullable
  `booking_page_id` on `theme_customizations` (a page's own colours) and on
  `meetings` (the page a booking came through). Existing customisation rows
  keep a NULL page id and stay the profile's, so the unique index on
  `(profile_id, theme_id)` becomes partial, admitting one row per page beside
  them.
  """

  use Ecto.Migration

  # Migrations run offline: `start.sh` executes them in a one-shot VM and only
  # starts Phoenix once they finish, so no request waits on these locks.
  # Both new reference columns are added in the statement that creates their
  # foreign key, so every existing row is NULL and nothing needs validating.
  # excellent_migrations:safety-assured-for-this-file column_reference_added
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  #
  # The deduplication guard and the rollback's cleanup are single set-based
  # statements.
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  #
  # `down/0` removes only what `up/0` added.
  # excellent_migrations:safety-assured-for-this-file column_removed
  # excellent_migrations:safety-assured-for-this-file table_dropped

  def up do
    create table(:booking_pages) do
      add :profile_id, references(:profiles, on_delete: :delete_all), null: false
      add :slug, :string, null: false
      add :name, :string, null: false
      add :booking_theme, :string, null: false
      add :booking_text_enabled, :boolean, null: false, default: false
      add :booking_heading, :string
      add :booking_greeting, :string
      add :booking_instruction, :string

      timestamps(type: :utc_datetime)
    end

    create index(:booking_pages, [:profile_id])
    create unique_index(:booking_pages, ["lower(slug)"], name: :booking_pages_slug_index)

    create table(:booking_page_meeting_types) do
      add :booking_page_id, references(:booking_pages, on_delete: :delete_all), null: false
      add :meeting_type_id, references(:meeting_types, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:booking_page_meeting_types, [:booking_page_id, :meeting_type_id])
    create index(:booking_page_meeting_types, [:meeting_type_id])

    alter table(:theme_customizations) do
      add :booking_page_id, references(:booking_pages, on_delete: :delete_all)
    end

    # Every existing row already satisfies the partial index below, since the
    # full index it replaces was stricter. This guards a database that arrived
    # here without that index (a restore, a hand-dropped index), keeping the
    # most recently updated row per profile and theme.
    execute("""
    DELETE FROM theme_customizations t
    USING theme_customizations keep
    WHERE t.booking_page_id IS NULL
      AND keep.booking_page_id IS NULL
      AND t.profile_id = keep.profile_id
      AND t.theme_id = keep.theme_id
      AND (t.updated_at, t.id) < (keep.updated_at, keep.id)
    """)

    drop_if_exists unique_index(:theme_customizations, [:profile_id, :theme_id])

    # Same name as the index it replaces, so `unique_constraint([:profile_id,
    # :theme_id])` in the schema keeps matching.
    create unique_index(:theme_customizations, [:profile_id, :theme_id],
             where: "booking_page_id IS NULL",
             name: :theme_customizations_profile_id_theme_id_index
           )

    create unique_index(:theme_customizations, [:booking_page_id, :theme_id])

    alter table(:meetings) do
      add :booking_page_id, references(:booking_pages, on_delete: :nilify_all)
    end

    # Partial: only bookings made through a page carry an id, and the index
    # exists so deleting a page finds them without scanning every meeting.
    create index(:meetings, [:booking_page_id], where: "booking_page_id IS NOT NULL")
  end

  def down do
    drop_if_exists index(:meetings, [:booking_page_id])

    alter table(:meetings) do
      remove :booking_page_id
    end

    drop_if_exists unique_index(:theme_customizations, [:booking_page_id, :theme_id])

    drop_if_exists unique_index(:theme_customizations, [:profile_id, :theme_id],
                     name: :theme_customizations_profile_id_theme_id_index
                   )

    # A page's rows would collide with the profile's once the full index is
    # back, and they mean nothing without their page.
    execute("DELETE FROM theme_customizations WHERE booking_page_id IS NOT NULL")

    alter table(:theme_customizations) do
      remove :booking_page_id
    end

    create unique_index(:theme_customizations, [:profile_id, :theme_id])

    drop table(:booking_page_meeting_types)
    drop table(:booking_pages)
  end
end
```

- [ ] **Step 4: Write the page schema**

```elixir
# lib/tymeslot/booking_pages/booking_page_schema.ex
defmodule Tymeslot.BookingPages.BookingPageSchema do
  @moduledoc """
  An extra public start page of a profile, at its own top-level address.

  The profile's own page at `/<username>` is not a row here: its theme and
  texts stay on the profile. A page carries the same page settings the profile
  does (the theme, and the three booking texts with their switch), so
  `Tymeslot.BookingPages.apply_to_profile/2` can lay a page over its owner's
  profile and everything that renders a start page reads the result unchanged.

  The address is trimmed and stored lowercase, follows the username rules and
  stays off the reserved list here; that it is free of every username and
  other page is checked by `Tymeslot.BookingPages`, with the unique index on
  `lower(slug)` as the backstop between pages.
  """
  use Ecto.Schema
  use Gettext, backend: TymeslotWeb.Gettext

  import Ecto.Changeset

  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Security.FieldValidators.UsernameValidator
  alias Tymeslot.Themes.Catalog

  @type t :: %__MODULE__{
          id: integer() | nil,
          profile_id: integer() | nil,
          slug: String.t() | nil,
          name: String.t() | nil,
          booking_theme: String.t() | nil,
          booking_text_enabled: boolean(),
          booking_heading: String.t() | nil,
          booking_greeting: String.t() | nil,
          booking_instruction: String.t() | nil,
          profile: ProfileSchema.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @name_max_length 60

  schema "booking_pages" do
    field(:slug, :string)
    field(:name, :string)
    field(:booking_theme, :string)
    field(:booking_text_enabled, :boolean, default: false)
    field(:booking_heading, :string)
    field(:booking_greeting, :string)
    field(:booking_instruction, :string)

    belongs_to(:profile, ProfileSchema)

    timestamps(type: :utc_datetime)
  end

  @doc "The longest a page name may be."
  @spec name_max_length() :: pos_integer()
  def name_max_length, do: @name_max_length

  @doc """
  A new page: its owner, starting theme, name and address.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(page, attrs) do
    page
    |> cast(attrs, [:profile_id, :booking_theme])
    |> validate_required([:profile_id, :booking_theme])
    |> validate_theme()
    |> details_changeset(attrs)
    |> foreign_key_constraint(:profile_id)
  end

  @doc """
  The page's name and address, as the dashboard edits them.
  """
  @spec details_changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def details_changeset(page_or_changeset, attrs) do
    page_or_changeset
    |> cast(attrs, [:name, :slug])
    |> update_change(:name, &String.trim/1)
    |> update_change(:slug, &normalize_slug/1)
    |> validate_required([:name, :slug])
    |> validate_length(:name, max: @name_max_length)
    |> validate_slug()
    |> unique_constraint(:slug, name: :booking_pages_slug_index)
  end

  @doc """
  Switches the page to another theme.
  """
  @spec theme_changeset(t(), String.t()) :: Ecto.Changeset.t()
  def theme_changeset(page, theme_id) do
    page
    |> cast(%{booking_theme: theme_id}, [:booking_theme])
    |> validate_required([:booking_theme])
    |> validate_theme()
  end

  defp normalize_slug(slug), do: slug |> String.trim() |> String.downcase()

  defp validate_slug(changeset) do
    validate_change(changeset, :slug, fn :slug, slug ->
      cond do
        UsernameValidator.validate(slug) != :ok -> [slug: address_format_message()]
        slug in Profiles.reserved_paths() -> [slug: {"is reserved", validation: :reserved}]
        true -> []
      end
    end)
  end

  # Not `UsernameValidator`'s own message: those name a username, and this is
  # a page's address. Built at call time so it follows the caller's locale.
  defp address_format_message do
    dgettext(
      "errors",
      "Use 3 to 30 lowercase letters, numbers, hyphens or underscores, starting with a letter or number"
    )
  end

  defp validate_theme(changeset) do
    validate_change(changeset, :booking_theme, fn :booking_theme, theme_id ->
      if Catalog.valid_id?(theme_id), do: [], else: [booking_theme: "is invalid"]
    end)
  end
end
```

- [ ] **Step 5: Write the join schema**

```elixir
# lib/tymeslot/booking_pages/booking_page_meeting_type_schema.ex
defmodule Tymeslot.BookingPages.BookingPageMeetingTypeSchema do
  @moduledoc """
  A meeting type listed on an extra booking page.

  Listing on the profile's own page at `/<username>` is not a row here: it
  stays `meeting_types.is_private == false`, as before pages existed.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Tymeslot.BookingPages.BookingPageSchema
  alias Tymeslot.MeetingTypes.MeetingTypeSchema

  @type t :: %__MODULE__{
          id: integer() | nil,
          booking_page_id: integer() | nil,
          meeting_type_id: integer() | nil,
          booking_page: BookingPageSchema.t() | Ecto.Association.NotLoaded.t(),
          meeting_type: MeetingTypeSchema.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "booking_page_meeting_types" do
    belongs_to(:booking_page, BookingPageSchema)
    belongs_to(:meeting_type, MeetingTypeSchema)

    timestamps(type: :utc_datetime)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(link, attrs) do
    link
    |> cast(attrs, [:booking_page_id, :meeting_type_id])
    |> validate_required([:booking_page_id, :meeting_type_id])
    |> foreign_key_constraint(:booking_page_id)
    |> foreign_key_constraint(:meeting_type_id)
    |> unique_constraint([:booking_page_id, :meeting_type_id])
  end
end
```

- [ ] **Step 6: Add `booking_page_id` to theme customisations**

In `lib/tymeslot/theme_customizations/theme_customization_schema.ex`:

Add the alias after `alias Tymeslot.Profiles.ProfileSchema`:

```elixir
  alias Tymeslot.BookingPages.BookingPageSchema
```

In `@type t`, after `profile_id: integer() | nil,` add:

```elixir
          booking_page_id: integer() | nil,
```

In the schema block, after `belongs_to(:profile, ProfileSchema, foreign_key: :profile_id)` add:

```elixir
    # Set for a booking page's own colours; NULL for the profile's own page.
    belongs_to(:booking_page, BookingPageSchema)
```

In `changeset/2`, add `:booking_page_id,` to the `cast` list after `:theme_id,`, and replace

```elixir
    |> unique_constraint([:profile_id, :theme_id])
```

with

```elixir
    |> foreign_key_constraint(:booking_page_id)
    |> unique_constraint([:profile_id, :theme_id])
    |> unique_constraint([:booking_page_id, :theme_id])
```

- [ ] **Step 7: Add `booking_page_id` to meetings**

In `lib/tymeslot/meetings/meeting_schema.ex`:

In `@type t`, after `visitor_hash: String.t() | nil,` (~line 101) add:

```elixir
          booking_page_id: integer() | nil,
```

In the schema block, after `field(:tracking_params, :map, default: %{})` (~line 314) add:

```elixir
    # The booking page the booking came through; nil for `/<username>`, a
    # direct link under it, or a booking that came through no page at all.
    field(:booking_page_id, :id)
```

In the cast field list, after `:visitor_hash` (~line 400) — the list ends `:tracking_params,\n    :visitor_hash\n  ]` — change the end to:

```elixir
    :tracking_params,
    :visitor_hash,
    :booking_page_id
  ]
```

In the changeset, after `|> foreign_key_constraint(:venue_id)` (~line 524) add:

```elixir
    |> foreign_key_constraint(:booking_page_id)
```

- [ ] **Step 8: Add the profile's virtual page and widen the booking-text spec**

In `lib/tymeslot/profiles/profile_schema.ex`, after `field(:meeting_types, {:array, :map}, virtual: true)` add:

```elixir
    # Set when this profile was resolved through one of its booking pages:
    # the page whose theme and texts `Tymeslot.BookingPages.apply_to_profile/2`
    # laid over these fields. Never persisted.
    field(:booking_page, :map, virtual: true)
```

and in `@type t` (after `booking_heading: String.t() | nil,`) add:

```elixir
          booking_page: map() | nil,
```

Replace the spec line of `booking_text_changeset/2`

```elixir
  @spec booking_text_changeset(t(), map()) :: Ecto.Changeset.t()
```

with

```elixir
  # Also applied to `Tymeslot.BookingPages.BookingPageSchema`, which carries
  # the same three fields and switch, so a page's texts follow the same rules.
  @spec booking_text_changeset(t() | struct(), map()) :: Ecto.Changeset.t()
```

- [ ] **Step 9: Add factories**

In `test/support/factory.ex`, add the aliases next to the other schema aliases:

```elixir
  alias Tymeslot.BookingPages.BookingPageMeetingTypeSchema
  alias Tymeslot.BookingPages.BookingPageSchema
```

and the factories after `theme_customization_factory/0`:

```elixir
  @spec booking_page_factory() :: Tymeslot.BookingPages.BookingPageSchema.t()
  def booking_page_factory do
    %BookingPageSchema{
      name: sequence(:booking_page_name, &"Page #{&1}"),
      slug: sequence(:booking_page_slug, &"page-#{&1}"),
      booking_theme: "1",
      profile: build(:profile)
    }
  end

  @spec booking_page_meeting_type_factory() ::
          Tymeslot.BookingPages.BookingPageMeetingTypeSchema.t()
  def booking_page_meeting_type_factory do
    %BookingPageMeetingTypeSchema{
      booking_page: build(:booking_page),
      meeting_type: build(:meeting_type)
    }
  end
```

- [ ] **Step 10: Run the test and the migration gate**

Run (mix): `test test/tymeslot/booking_pages/booking_page_schema_test.exs`
Expected: 6 tests, 0 failures.

Run (mix, `MIX_ENV=dev`): `excellent_migrations.check_safety`
Expected: no dangerous operations reported for `20261009120000_create_booking_pages.exs`. If it names a danger type the comments above do not cover, add a `safety-assured-for-this-file` line for that exact type with a one-line reason.

- [ ] **Step 11: Commit**

```bash
git add priv/repo/migrations/20261009120000_create_booking_pages.exs lib/tymeslot/booking_pages/ \
  lib/tymeslot/theme_customizations/theme_customization_schema.ex lib/tymeslot/meetings/meeting_schema.ex \
  lib/tymeslot/profiles/profile_schema.ex test/support/factory.ex test/tymeslot/booking_pages/
git commit -m "feat(booking-pages): add the booking pages tables and schemas"
```

---

### Task 2: Theme customisations scoped to a page

**Files:**
- Modify: `lib/tymeslot/theme_customizations/theme_customization_queries.ex`
- Modify: `lib/tymeslot/theme_customizations.ex`
- Test: `test/tymeslot/theme_customizations/page_scope_test.exs`

**Interfaces:**
- Consumes: `ThemeCustomizationSchema.booking_page_id` (Task 1).
- Produces: `@type ThemeCustomizations.scope :: pos_integer() | {pos_integer(), pos_integer()}` (profile id, or `{profile_id, page_id}`).
- Produces: `ThemeCustomizations.scope_for(map()) :: scope()` — `{profile.id, page.id}` for a profile carrying `booking_page: %{id: page_id}`, else `profile.id`.
- Produces: every existing `ThemeCustomizations` function whose first argument was `profile_id` (`get_by_profile_and_theme/2`, `upsert_theme_customization/3`, `create_theme_customization/3`, `initialize_customization/2`, `apply_color_scheme_change/4`, `apply_custom_palette_change/4`, `apply_background_change/5`, `store_background_image/3`, `store_background_video/3`) now accepts a `scope()`; a plain profile id behaves exactly as before.
- Produces: `ThemeCustomizations.copy_to_page(profile_id :: pos_integer(), page_id :: pos_integer()) :: :ok`.
- Produces: `ThemeCustomizations.delete_page_customizations(page_id :: pos_integer()) :: :ok`.

- [ ] **Step 1: Write the failing test**

```elixir
# test/tymeslot/theme_customizations/page_scope_test.exs
defmodule Tymeslot.ThemeCustomizations.PageScopeTest do
  use Tymeslot.DataCase, async: true

  @moduletag :themes

  import Tymeslot.Factory

  alias Tymeslot.Repo
  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema

  setup do
    profile = insert(:profile)
    page = insert(:booking_page, profile: profile)
    %{profile: profile, page: page}
  end

  test "the profile's row is found when a page row exists for the same theme", ctx do
    insert(:theme_customization, profile: ctx.profile, theme_id: "1", color_scheme: "ocean")

    insert(:theme_customization,
      profile: ctx.profile,
      booking_page: ctx.page,
      theme_id: "1",
      color_scheme: "rose"
    )

    assert %{color_scheme: "ocean"} = ThemeCustomizations.get_by_profile_and_theme(ctx.profile.id, "1")

    assert %{color_scheme: "rose"} =
             ThemeCustomizations.get_by_profile_and_theme({ctx.profile.id, ctx.page.id}, "1")
  end

  test "an upsert in page scope writes the page's row and leaves the profile's alone", ctx do
    insert(:theme_customization, profile: ctx.profile, theme_id: "1", color_scheme: "ocean")

    scope = {ctx.profile.id, ctx.page.id}
    %{customization: current} = ThemeCustomizations.initialize_customization(scope, "1")

    {:ok, page_row} = ThemeCustomizations.apply_color_scheme_change(scope, "1", current, "purple")

    assert page_row.booking_page_id == ctx.page.id
    assert page_row.color_scheme == "purple"
    assert %{color_scheme: "ocean"} = ThemeCustomizations.get_by_profile_and_theme(ctx.profile.id, "1")
  end

  test "scope_for reads a page off an overlaid profile", ctx do
    assert ThemeCustomizations.scope_for(ctx.profile) == ctx.profile.id

    assert ThemeCustomizations.scope_for(%{ctx.profile | booking_page: ctx.page}) ==
             {ctx.profile.id, ctx.page.id}
  end

  test "copy_to_page copies colours and gradients but not uploaded backgrounds", ctx do
    insert(:theme_customization,
      profile: ctx.profile,
      theme_id: "1",
      color_scheme: "ocean",
      background_type: "gradient",
      background_value: "gradient_3"
    )

    insert(:theme_customization,
      profile: ctx.profile,
      theme_id: "2",
      color_scheme: "rose",
      background_type: "image",
      background_value: "custom",
      background_image_path: "1/2/uploaded.jpg"
    )

    assert :ok = ThemeCustomizations.copy_to_page(ctx.profile.id, ctx.page.id)

    quill = ThemeCustomizations.get_by_profile_and_theme({ctx.profile.id, ctx.page.id}, "1")
    rhythm = ThemeCustomizations.get_by_profile_and_theme({ctx.profile.id, ctx.page.id}, "2")

    assert %{color_scheme: "ocean", background_type: "gradient", background_value: "gradient_3"} =
             quill

    # Rhythm's own default background stands in for the uploaded image.
    assert rhythm.color_scheme == "rose"
    assert rhythm.background_image_path == nil
    assert {rhythm.background_type, rhythm.background_value} == {"video", "preset:rhythm-default"}
  end

  test "delete_page_customizations removes only the page's rows", ctx do
    insert(:theme_customization, profile: ctx.profile, theme_id: "1")
    insert(:theme_customization, profile: ctx.profile, booking_page: ctx.page, theme_id: "1")

    assert :ok = ThemeCustomizations.delete_page_customizations(ctx.page.id)

    assert [%{booking_page_id: nil}] = Repo.all(ThemeCustomizationSchema)
  end
end
```

- [ ] **Step 2: Run it to see it fail**

Run (mix): `test test/tymeslot/theme_customizations/page_scope_test.exs`
Expected: the first test fails with `Ecto.MultipleResultsError`; the others fail on undefined `scope_for/1`, `copy_to_page/2`, `delete_page_customizations/1`, or a tuple scope not matching.

- [ ] **Step 3: Scope the queries**

In `lib/tymeslot/theme_customizations/theme_customization_queries.ex`, replace `get_by_profile_and_theme/2` with:

```elixir
  @doc """
  Gets the profile's own customization for a theme: the one for its page at
  `/<username>`, never one of its booking pages'.
  """
  @spec get_by_profile_and_theme(integer(), String.t()) :: ThemeCustomizationSchema.t() | nil
  def get_by_profile_and_theme(profile_id, theme_id) do
    ThemeCustomizationSchema
    |> where([tc], tc.profile_id == ^profile_id and tc.theme_id == ^theme_id)
    |> where([tc], is_nil(tc.booking_page_id))
    |> Repo.one()
  end

  @doc """
  Gets a booking page's customization for a theme.
  """
  @spec get_by_page_and_theme(integer(), String.t()) :: ThemeCustomizationSchema.t() | nil
  def get_by_page_and_theme(page_id, theme_id) do
    Repo.get_by(ThemeCustomizationSchema, booking_page_id: page_id, theme_id: theme_id)
  end

  @doc """
  The profile's own customizations, one per theme it has customised.
  """
  @spec list_for_profile_page(integer()) :: [ThemeCustomizationSchema.t()]
  def list_for_profile_page(profile_id) do
    ThemeCustomizationSchema
    |> where([tc], tc.profile_id == ^profile_id and is_nil(tc.booking_page_id))
    |> Repo.all()
  end

  @doc """
  A booking page's customizations.
  """
  @spec list_by_page(integer()) :: [ThemeCustomizationSchema.t()]
  def list_by_page(page_id) do
    ThemeCustomizationSchema
    |> where([tc], tc.booking_page_id == ^page_id)
    |> Repo.all()
  end
```

- [ ] **Step 4: Scope the context**

In `lib/tymeslot/theme_customizations.ex`:

Add the type after `@type profile_id :: pos_integer()`:

```elixir
  @typedoc """
  Whose customizations: a profile id for its own page at `/<username>`, or
  `{profile_id, page_id}` for one of its booking pages.
  """
  @type scope :: profile_id() | {profile_id(), pos_integer()}
```

Replace `get_by_profile_and_theme/2` with:

```elixir
  @doc """
  Gets a theme customization by scope (see `t:scope/0`) and theme ID.
  """
  @spec get_by_profile_and_theme(scope(), theme_id()) :: ThemeCustomizationSchema.t() | nil
  def get_by_profile_and_theme({_profile_id, page_id}, theme_id),
    do: ThemeCustomizationQueries.get_by_page_and_theme(page_id, theme_id)

  def get_by_profile_and_theme(profile_id, theme_id),
    do: ThemeCustomizationQueries.get_by_profile_and_theme(profile_id, theme_id)

  @doc """
  The scope a profile's start page reads its colours from: the booking page it
  was resolved through (`Tymeslot.BookingPages.apply_to_profile/2`), or the
  profile's own.
  """
  @spec scope_for(map()) :: scope()
  def scope_for(%{id: profile_id, booking_page: %{id: page_id}}), do: {profile_id, page_id}
  def scope_for(%{id: profile_id}), do: profile_id
```

In `upsert_theme_customization/3`, `create_theme_customization/3`, `initialize_customization/2`, `apply_color_scheme_change/4`, `apply_custom_palette_change/4`, `apply_background_change/5`: rename the first parameter from `profile_id` to `scope` in the head and every use in the body, and change `profile_id()` to `scope()` in their `@spec`s. Then make these three edits:

In `create_theme_customization/3`, replace

```elixir
    attrs =
      attrs
      |> Map.put("profile_id", profile_id)
      |> Map.put("theme_id", theme_id)
```

with

```elixir
    attrs =
      attrs
      |> Map.merge(scope_attrs(scope))
      |> Map.put("theme_id", theme_id)
```

In `initialize_customization/2`, replace

```elixir
    customization = Defaults.build_initial_customization(profile_id, theme_id, saved)
```

with

```elixir
    customization = Defaults.build_initial_customization(profile_id_of(scope), theme_id, saved)
```

Replace `has_unique_constraint_error?/1` with:

```elixir
  # Either unique index: the profile's own row or a page's.
  defp has_unique_constraint_error?(changeset) do
    Enum.any?(changeset.errors, fn {field, {_msg, opts}} ->
      field in [:profile_id, :booking_page_id] and Keyword.get(opts, :constraint) == :unique
    end)
  end
```

In `store_background_image/3` and `store_background_video/3`, rename the first parameter to `scope`, change its spec type to `scope()`, and pass `profile_id_of(scope)` to `Storage` (uploads live in the profile's directory whichever page they are for).

Add, before `# Private functions`:

```elixir
  @doc """
  Gives a new booking page copies of its profile's customizations.

  Colour schemes, palettes, gradients, plain colours and preset backgrounds are
  copied. An uploaded image or video background is not: the page gets that
  theme's default background instead, since a file shared between two rows
  would be deleted from under one of them when the other replaced it.
  """
  @spec copy_to_page(profile_id(), pos_integer()) :: :ok
  def copy_to_page(profile_id, page_id) do
    profile_id
    |> ThemeCustomizationQueries.list_for_profile_page()
    |> Enum.each(fn row ->
      {:ok, _copy} =
        create_theme_customization({profile_id, page_id}, row.theme_id, copy_attrs(row))
    end)
  end

  @doc """
  Deletes a booking page's customizations and their uploaded files.
  """
  @spec delete_page_customizations(pos_integer()) :: :ok
  def delete_page_customizations(page_id) do
    page_id
    |> ThemeCustomizationQueries.list_by_page()
    |> Enum.each(&delete_theme_customization/1)
  end

  defp copy_attrs(%{background_image_path: nil, background_video_path: nil} = row) do
    %{
      "color_scheme" => row.color_scheme,
      "custom_palette_seed" => row.custom_palette_seed,
      "background_type" => row.background_type,
      "background_value" => row.background_value
    }
  end

  defp copy_attrs(row) do
    defaults = Defaults.get_theme_defaults(row.theme_id)

    %{
      "color_scheme" => row.color_scheme,
      "custom_palette_seed" => row.custom_palette_seed,
      "background_type" => defaults.background_type,
      "background_value" => defaults.background_value
    }
  end

  defp scope_attrs({profile_id, page_id}),
    do: %{"profile_id" => profile_id, "booking_page_id" => page_id}

  defp scope_attrs(profile_id), do: %{"profile_id" => profile_id}

  defp profile_id_of({profile_id, _page_id}), do: profile_id
  defp profile_id_of(profile_id), do: profile_id
```

- [ ] **Step 5: Run the tests**

Run (mix): `test test/tymeslot/theme_customizations/page_scope_test.exs test/tymeslot/theme_customizations`
Expected: all pass. The second path is the existing customization suite, unchanged in behaviour for plain profile ids.

- [ ] **Step 6: Commit**

```bash
git add lib/tymeslot/theme_customizations.ex lib/tymeslot/theme_customizations/theme_customization_queries.ex \
  test/tymeslot/theme_customizations/page_scope_test.exs
git commit -m "feat(booking-pages): scope theme customizations to a booking page"
```

---

### Task 3: The booking pages context

**Files:**
- Create: `lib/tymeslot/booking_pages/booking_page_queries.ex`
- Create: `lib/tymeslot/booking_pages.ex`
- Test: `test/tymeslot/booking_pages_test.exs`

**Interfaces:**
- Consumes: `BookingPageSchema` (Task 1); `ThemeCustomizations.copy_to_page/2`, `delete_page_customizations/1` (Task 2); `Profiles.username_available?/1` (existing; extended in Task 4).
- Produces (context `Tymeslot.BookingPages`):
  - `max_pages() :: pos_integer()` (10)
  - `list(profile_id) :: [BookingPageSchema.t()]` (oldest first)
  - `fetch(profile_id, id :: integer() | String.t()) :: {:ok, page} | {:error, :not_found}`
  - `change_new(profile, attrs) :: Ecto.Changeset.t()` (live validation of the new-page form, namespace included, `action: :validate`)
  - `create(profile, attrs) :: {:ok, page} | {:error, :limit_reached} | {:error, Ecto.Changeset.t()}`
  - `change_details(page, attrs) :: Ecto.Changeset.t()`
  - `update_details(page, attrs) :: {:ok, page} | {:error, Ecto.Changeset.t()}`
  - `update_theme(page, theme_id) :: {:ok, page} | {:error, Ecto.Changeset.t()}`
  - `update_booking_text(page, attrs) :: {:ok, page} | {:error, Ecto.Changeset.t()}`
  - `delete(page) :: {:ok, page} | {:error, term()}`
- Produces (queries `Tymeslot.BookingPages.BookingPageQueries`): `list_for_profile/1`, `count_for_profile/1`, `get_for_profile/2`, `get/1`, `get_by_slug/2`, `slug_taken?/1`, `exists?/1`, `insert/1`, `update/1`, `delete/1`.

- [ ] **Step 1: Write the failing test**

```elixir
# test/tymeslot/booking_pages_test.exs
defmodule Tymeslot.BookingPagesTest do
  use Tymeslot.DataCase, async: true

  @moduletag :profiles

  import Tymeslot.Factory

  alias Tymeslot.BookingPages
  alias Tymeslot.ThemeCustomizations

  setup do
    user = insert(:user)
    profile = insert(:profile, user: user, username: "joern", booking_theme: "2")
    %{user: user, profile: profile}
  end

  describe "create/2" do
    test "creates a page on the profile's theme with its colours copied", %{profile: profile} do
      insert(:theme_customization, profile: profile, theme_id: "2", color_scheme: "ocean")

      assert {:ok, page} =
               BookingPages.create(profile, %{"name" => "einfachISO", "slug" => " EinfachISO "})

      assert page.slug == "einfachiso"
      assert page.booking_theme == "2"
      assert page.booking_text_enabled == false

      assert %{color_scheme: "ocean"} =
               ThemeCustomizations.get_by_profile_and_theme({profile.id, page.id}, "2")
    end

    test "refuses an address that is a username", %{profile: profile} do
      insert(:profile, username: "taken-name")

      assert {:error, changeset} =
               BookingPages.create(profile, %{"name" => "X", "slug" => "Taken-Name"})

      assert {"has already been taken", _opts} = changeset.errors[:slug]
    end

    test "refuses an address another page holds, whatever its case", %{profile: profile} do
      insert(:booking_page, slug: "einfachiso")

      assert {:error, changeset} =
               BookingPages.create(profile, %{"name" => "X", "slug" => "EINFACHISO"})

      assert {"has already been taken", _opts} = changeset.errors[:slug]
    end

    test "stops at the cap", %{profile: profile} do
      for n <- 1..BookingPages.max_pages() do
        insert(:booking_page, profile: profile, slug: "cap-page-#{n}")
      end

      assert {:error, :limit_reached} =
               BookingPages.create(profile, %{"name" => "One more", "slug" => "one-more"})
    end
  end

  describe "update_details/2" do
    test "keeping its own address is not a clash", %{profile: profile} do
      page = insert(:booking_page, profile: profile, slug: "einfachiso", name: "Old")

      assert {:ok, %{name: "New", slug: "einfachiso"}} =
               BookingPages.update_details(page, %{"name" => "New", "slug" => "einfachiso"})
    end

    test "moving to a username's address is refused", %{profile: profile} do
      page = insert(:booking_page, profile: profile, slug: "einfachiso")

      assert {:error, changeset} =
               BookingPages.update_details(page, %{"name" => "X", "slug" => "joern"})

      assert {"has already been taken", _opts} = changeset.errors[:slug]
    end
  end

  test "update_theme/2 changes only the page", %{profile: profile} do
    page = insert(:booking_page, profile: profile, booking_theme: "2")

    assert {:ok, %{booking_theme: "1"}} = BookingPages.update_theme(page, "1")
    assert Tymeslot.Repo.reload!(profile).booking_theme == "2"
  end

  test "update_booking_text/2 applies the profile's rules", %{profile: profile} do
    page = insert(:booking_page, profile: profile)

    assert {:error, changeset} =
             BookingPages.update_booking_text(page, %{"booking_text_enabled" => "true"})

    assert changeset.errors[:booking_heading]

    assert {:ok, page} =
             BookingPages.update_booking_text(page, %{
               "booking_text_enabled" => "true",
               "booking_heading" => "  Consulting  ",
               "booking_greeting" => "Hi",
               "booking_instruction" => "Pick one"
             })

    assert page.booking_heading == "Consulting"
  end

  test "delete/1 removes the page and its colours, not the profile's", %{profile: profile} do
    page = insert(:booking_page, profile: profile)
    insert(:theme_customization, profile: profile, theme_id: "1")
    insert(:theme_customization, profile: profile, booking_page: page, theme_id: "1")

    assert {:ok, _deleted} = BookingPages.delete(page)
    assert BookingPages.list(profile.id) == []
    assert ThemeCustomizations.get_by_profile_and_theme(profile.id, "1")
  end

  test "fetch/2 only finds the profile's own pages", %{profile: profile} do
    mine = insert(:booking_page, profile: profile)
    theirs = insert(:booking_page)

    assert {:ok, %{id: id}} = BookingPages.fetch(profile.id, to_string(mine.id))
    assert id == mine.id
    assert {:error, :not_found} = BookingPages.fetch(profile.id, theirs.id)
    assert {:error, :not_found} = BookingPages.fetch(profile.id, "nonsense")
  end
end
```

- [ ] **Step 2: Run it to see it fail**

Run (mix): `test test/tymeslot/booking_pages_test.exs`
Expected: compilation error, `Tymeslot.BookingPages` is undefined.

- [ ] **Step 3: Write the queries module**

```elixir
# lib/tymeslot/booking_pages/booking_page_queries.ex
defmodule Tymeslot.BookingPages.BookingPageQueries do
  @moduledoc """
  Database access for booking pages.
  """
  import Ecto.Query, warn: false

  alias Tymeslot.BookingPages.BookingPageSchema
  alias Tymeslot.Repo

  @doc "A profile's pages, oldest first."
  @spec list_for_profile(integer()) :: [BookingPageSchema.t()]
  def list_for_profile(profile_id) do
    BookingPageSchema
    |> where([p], p.profile_id == ^profile_id)
    |> order_by([p], asc: p.inserted_at, asc: p.id)
    |> Repo.all()
  end

  @doc "How many pages a profile holds."
  @spec count_for_profile(integer()) :: non_neg_integer()
  def count_for_profile(profile_id) do
    BookingPageSchema
    |> where([p], p.profile_id == ^profile_id)
    |> Repo.aggregate(:count)
  end

  @doc "One of a profile's pages, scoped so an id can never reach another profile's."
  @spec get_for_profile(integer(), integer()) :: BookingPageSchema.t() | nil
  def get_for_profile(profile_id, id), do: Repo.get_by(BookingPageSchema, id: id, profile_id: profile_id)

  @doc "A page by id."
  @spec get(integer()) :: BookingPageSchema.t() | nil
  def get(id), do: Repo.get(BookingPageSchema, id)

  @doc """
  The page at `slug`, with `preload` loaded. Addresses are stored lowercase,
  so this is an exact match, as a username lookup is.
  """
  @spec get_by_slug(String.t(), list()) :: BookingPageSchema.t() | nil
  def get_by_slug(slug, preload \\ []) do
    BookingPageSchema
    |> where([p], p.slug == ^slug)
    |> preload(^preload)
    |> Repo.one()
  end

  @doc "Whether any page holds `slug`, ignoring case, as the unique index does."
  @spec slug_taken?(String.t()) :: boolean()
  def slug_taken?(slug) do
    normalised = String.downcase(slug)
    Repo.exists?(from(p in BookingPageSchema, where: fragment("lower(?)", p.slug) == ^normalised))
  end

  @doc "Whether a page with `id` exists."
  @spec exists?(integer()) :: boolean()
  def exists?(id), do: Repo.exists?(from(p in BookingPageSchema, where: p.id == ^id))

  @doc false
  @spec insert(Ecto.Changeset.t()) :: {:ok, BookingPageSchema.t()} | {:error, Ecto.Changeset.t()}
  def insert(changeset), do: Repo.insert(changeset)

  @doc false
  @spec update(Ecto.Changeset.t()) :: {:ok, BookingPageSchema.t()} | {:error, Ecto.Changeset.t()}
  def update(changeset), do: Repo.update(changeset)

  @doc false
  @spec delete(BookingPageSchema.t()) :: {:ok, BookingPageSchema.t()} | {:error, Ecto.Changeset.t()}
  def delete(page), do: Repo.delete(page)
end
```

- [ ] **Step 4: Write the context**

```elixir
# lib/tymeslot/booking_pages.ex
defmodule Tymeslot.BookingPages do
  @moduledoc """
  Booking pages: extra public start pages of a profile, each at its own
  top-level address with its own theme, colours, texts and meeting types.

  The profile's own page at `/<username>` is not one of these; it stays on the
  profile. An address shares one namespace with usernames and reserved paths,
  so neither can take the other's.
  """
  alias Ecto.Changeset
  alias Tymeslot.BookingPages.BookingPageQueries
  alias Tymeslot.BookingPages.BookingPageSchema
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Repo
  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.Themes.Catalog

  @type page :: BookingPageSchema.t()

  @max_pages 10

  @doc "The most extra pages one profile may hold."
  @spec max_pages() :: pos_integer()
  def max_pages, do: @max_pages

  @doc "A profile's pages, oldest first."
  @spec list(integer()) :: [page()]
  def list(profile_id), do: BookingPageQueries.list_for_profile(profile_id)

  @doc """
  One of a profile's pages. `id` may come straight from a URL or an event, so
  a string that is not a whole number is simply not found.
  """
  @spec fetch(integer(), integer() | String.t()) :: {:ok, page()} | {:error, :not_found}
  def fetch(profile_id, id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> fetch(profile_id, int)
      _not_an_id -> {:error, :not_found}
    end
  end

  def fetch(profile_id, id) when is_integer(id) do
    case BookingPageQueries.get_for_profile(profile_id, id) do
      nil -> {:error, :not_found}
      page -> {:ok, page}
    end
  end

  @doc """
  The new-page form's changeset, address namespace included, for showing
  errors while the host types.
  """
  @spec change_new(ProfileSchema.t(), map()) :: Changeset.t()
  def change_new(%ProfileSchema{} = profile, attrs) do
    profile
    |> new_changeset(attrs)
    |> Map.put(:action, :validate)
  end

  @doc """
  Creates a page for `profile` on the profile's current theme, with copies of
  its colours (`ThemeCustomizations.copy_to_page/2`). Texts start switched off
  and no meeting types are listed.
  """
  @spec create(ProfileSchema.t(), map()) ::
          {:ok, page()} | {:error, :limit_reached} | {:error, Changeset.t()}
  def create(%ProfileSchema{} = profile, attrs) do
    if BookingPageQueries.count_for_profile(profile.id) >= @max_pages do
      {:error, :limit_reached}
    else
      Repo.transaction(fn ->
        with {:ok, page} <- profile |> new_changeset(attrs) |> BookingPageQueries.insert(),
             :ok <- ThemeCustomizations.copy_to_page(profile.id, page.id) do
          page
        else
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
    end
  end

  @doc "The details form's changeset, address namespace included."
  @spec change_details(page(), map()) :: Changeset.t()
  def change_details(%BookingPageSchema{} = page, attrs) do
    page
    |> BookingPageSchema.details_changeset(attrs)
    |> validate_address_free(page.slug)
    |> Map.put(:action, :validate)
  end

  @doc "Renames a page or moves it to another address."
  @spec update_details(page(), map()) :: {:ok, page()} | {:error, Changeset.t()}
  def update_details(%BookingPageSchema{} = page, attrs) do
    page
    |> BookingPageSchema.details_changeset(attrs)
    |> validate_address_free(page.slug)
    |> BookingPageQueries.update()
  end

  @doc "Switches a page to another theme."
  @spec update_theme(page(), String.t()) :: {:ok, page()} | {:error, Changeset.t()}
  def update_theme(%BookingPageSchema{} = page, theme_id) do
    page
    |> BookingPageSchema.theme_changeset(theme_id)
    |> BookingPageQueries.update()
  end

  @doc """
  Saves a page's booking texts, under the rules the profile's own follow
  (`ProfileSchema.booking_text_changeset/2`).
  """
  @spec update_booking_text(page(), map()) :: {:ok, page()} | {:error, Changeset.t()}
  def update_booking_text(%BookingPageSchema{} = page, attrs) do
    page
    |> ProfileSchema.booking_text_changeset(attrs)
    |> BookingPageQueries.update()
  end

  @doc """
  Deletes a page. Its colours go first, through `ThemeCustomizations`, so
  their uploaded background files are removed too; the database would drop the
  rows on its own but leave the files behind. Its meeting type listings go
  with the page, and its bookings keep everything but the page id.
  """
  @spec delete(page()) :: {:ok, page()} | {:error, term()}
  def delete(%BookingPageSchema{} = page) do
    :ok = ThemeCustomizations.delete_page_customizations(page.id)
    BookingPageQueries.delete(page)
  end

  defp new_changeset(profile, attrs) do
    %BookingPageSchema{}
    |> BookingPageSchema.create_changeset(
      Map.merge(stringify(attrs), %{
        "profile_id" => profile.id,
        "booking_theme" => profile.booking_theme || Catalog.default_id()
      })
    )
    |> validate_address_free(nil)
  end

  defp stringify(attrs), do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

  # The page's own current address is never a clash with itself. Otherwise
  # `Profiles.username_available?/1` answers for usernames and pages alike
  # (Task 4), case-insensitively; the unique index settles a race between
  # pages, and resolution lets a username win a race against a page.
  defp validate_address_free(changeset, current_slug) do
    Changeset.validate_change(changeset, :slug, fn :slug, slug ->
      cond do
        slug == current_slug -> []
        Profiles.username_available?(slug) -> []
        true -> [slug: {"has already been taken", validation: :unsafe_unique}]
      end
    end)
  end
end
```

- [ ] **Step 5: Run the test**

Run (mix): `test test/tymeslot/booking_pages_test.exs`
Expected: 10 tests, 0 failures. ("refuses an address another page holds" already passes here through the `lower(slug)` unique index; Task 4 makes the namespace check itself see pages.)

- [ ] **Step 6: Commit**

```bash
git add lib/tymeslot/booking_pages.ex lib/tymeslot/booking_pages/booking_page_queries.ex test/tymeslot/booking_pages_test.exs
git commit -m "feat(booking-pages): add the booking pages context"
```

---

### Task 4: One namespace for usernames and page addresses

**Files:**
- Modify: `lib/tymeslot/profiles/profile_queries.ex` (`username_available?/1`, ~line 150)
- Modify: `docs/superpowers/specs/2026-10-09-booking-pages-design.md` (Address namespace section)
- Test: `test/tymeslot/profiles/username_page_namespace_test.exs`

**Interfaces:**
- Consumes: `BookingPageQueries.slug_taken?/1` (Task 3).
- Produces: `ProfileQueries.username_available?/1` (and through it `Profiles.username_available?/1`, `Profiles.username_status/2`, `Profiles.Usernames`) answers `false` for any page address.

- [ ] **Step 1: Write the failing test**

```elixir
# test/tymeslot/profiles/username_page_namespace_test.exs
defmodule Tymeslot.Profiles.UsernamePageNamespaceTest do
  use Tymeslot.DataCase, async: true

  @moduletag :profiles

  import Tymeslot.Factory

  alias Tymeslot.Profiles

  test "a page's address is not available as a username" do
    insert(:booking_page, slug: "einfachiso")

    refute Profiles.username_available?("einfachiso")
    refute Profiles.username_available?("EinfachISO")
    assert Profiles.username_status(insert(:profile), "einfachiso") == :taken
  end

  test "an address no page or profile holds is available" do
    assert Profiles.username_available?("nobody-has-this")
  end
end
```

- [ ] **Step 2: Run it to see it fail**

Run (mix): `test test/tymeslot/profiles/username_page_namespace_test.exs`
Expected: FAIL, `username_available?("einfachiso")` is `true`.

- [ ] **Step 3: Extend the check**

In `lib/tymeslot/profiles/profile_queries.ex`, add the alias:

```elixir
  alias Tymeslot.BookingPages.BookingPageQueries
```

and replace the body of `username_available?/1`:

```elixir
  def username_available?(username) when is_binary(username) do
    normalised = String.downcase(username)

    not Repo.exists?(
      from(p in ProfileSchema, where: fragment("lower(?)", p.username) == ^normalised)
    ) and not BookingPageQueries.slug_taken?(normalised)
  end
```

Append to its `@doc`:

```
  Booking page addresses share the namespace (`Tymeslot.BookingPages`), so an
  address any page holds is not available either.
```

- [ ] **Step 4: Bring the spec in line**

In `docs/superpowers/specs/2026-10-09-booking-pages-design.md`, section "Address namespace", replace the bullet

```
- `Profiles.username_status/2` and the profile changeset reject a username
  that is any page's address.
```

with

```
- `ProfileQueries.username_available?/1`, which every username check goes
  through (`Profiles.username_status/2`, default usernames), rejects any
  page's address. The profile changeset itself stays a database uniqueness
  check, as before.
```

- [ ] **Step 5: Run the tests**

Run (mix): `test test/tymeslot/profiles test/tymeslot/booking_pages_test.exs`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add lib/tymeslot/profiles/profile_queries.ex test/tymeslot/profiles/username_page_namespace_test.exs \
  docs/superpowers/specs/2026-10-09-booking-pages-design.md
git commit -m "feat(booking-pages): keep usernames off booking page addresses"
```

---

### Task 5: Meeting types on pages

**Files:**
- Modify: `lib/tymeslot/booking_pages/booking_page_queries.ex`
- Modify: `lib/tymeslot/booking_pages.ex`
- Test: `test/tymeslot/booking_pages/membership_test.exs`

**Interfaces:**
- Consumes: `BookingPageMeetingTypeSchema` (Task 1); `Tymeslot.MeetingTypes.GroupAccess.reject_paused/1` (existing).
- Produces: `BookingPages.set_meeting_type(page, meeting_type_id, listed? :: boolean()) :: :ok`
- Produces: `BookingPages.list_meeting_types(page) :: [MeetingTypeSchema.t()]` — listed, active, not paused, by `sort_order` then name, preloaded like the public list.
- Produces: `BookingPages.memberships(profile_id) :: %{optional(integer()) => MapSet.t(integer())}` — meeting type id ⇒ ids of the extra pages it is listed on.
- Produces (queries): `add_meeting_type/2`, `remove_meeting_type/2`, `list_meeting_types/1`, `memberships_for_profile/1`.

- [ ] **Step 1: Write the failing test**

```elixir
# test/tymeslot/booking_pages/membership_test.exs
defmodule Tymeslot.BookingPages.MembershipTest do
  use Tymeslot.DataCase, async: true

  @moduletag :profiles
  @moduletag :meeting_types

  import Tymeslot.Factory

  alias Tymeslot.BookingPages

  setup do
    user = insert(:user)
    profile = insert(:profile, user: user)
    page = insert(:booking_page, profile: profile)
    %{user: user, profile: profile, page: page}
  end

  test "lists the types ticked for the page, in the host's order", ctx do
    second = insert(:meeting_type, user: ctx.user, name: "B", sort_order: 2)
    first = insert(:meeting_type, user: ctx.user, name: "A", sort_order: 1)
    _unticked = insert(:meeting_type, user: ctx.user, name: "C", sort_order: 0)

    :ok = BookingPages.set_meeting_type(ctx.page, second.id, true)
    :ok = BookingPages.set_meeting_type(ctx.page, first.id, true)

    assert ctx.page |> BookingPages.list_meeting_types() |> Enum.map(& &1.name) == ["A", "B"]
  end

  test "leaves out inactive types and types with no rows", ctx do
    inactive = insert(:meeting_type, user: ctx.user, is_active: false)
    :ok = BookingPages.set_meeting_type(ctx.page, inactive.id, true)

    assert BookingPages.list_meeting_types(ctx.page) == []
  end

  test "ticking twice and unticking are both safe", ctx do
    type = insert(:meeting_type, user: ctx.user)

    :ok = BookingPages.set_meeting_type(ctx.page, type.id, true)
    :ok = BookingPages.set_meeting_type(ctx.page, type.id, true)
    assert [_one] = BookingPages.list_meeting_types(ctx.page)

    :ok = BookingPages.set_meeting_type(ctx.page, type.id, false)
    :ok = BookingPages.set_meeting_type(ctx.page, type.id, false)
    assert BookingPages.list_meeting_types(ctx.page) == []
  end

  test "memberships maps each type to its pages", ctx do
    other_page = insert(:booking_page, profile: ctx.profile)
    type = insert(:meeting_type, user: ctx.user)
    lonely = insert(:meeting_type, user: ctx.user)

    :ok = BookingPages.set_meeting_type(ctx.page, type.id, true)
    :ok = BookingPages.set_meeting_type(other_page, type.id, true)

    memberships = BookingPages.memberships(ctx.profile.id)

    assert memberships[type.id] == MapSet.new([ctx.page.id, other_page.id])
    refute Map.has_key?(memberships, lonely.id)
  end
end
```

- [ ] **Step 2: Run it to see it fail**

Run (mix): `test test/tymeslot/booking_pages/membership_test.exs`
Expected: FAIL, `BookingPages.set_meeting_type/3` is undefined.

- [ ] **Step 3: Add the queries**

In `lib/tymeslot/booking_pages/booking_page_queries.ex`, add aliases:

```elixir
  alias Tymeslot.BookingPages.BookingPageMeetingTypeSchema
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
```

and the functions:

```elixir
  @doc "Lists a meeting type on a page; listing it again is a no-op."
  @spec add_meeting_type(integer(), integer()) :: :ok
  def add_meeting_type(page_id, meeting_type_id) do
    %BookingPageMeetingTypeSchema{}
    |> BookingPageMeetingTypeSchema.changeset(%{
      booking_page_id: page_id,
      meeting_type_id: meeting_type_id
    })
    |> Repo.insert!(on_conflict: :nothing, conflict_target: [:booking_page_id, :meeting_type_id])

    :ok
  end

  @doc "Takes a meeting type off a page; one not listed is a no-op."
  @spec remove_meeting_type(integer(), integer()) :: :ok
  def remove_meeting_type(page_id, meeting_type_id) do
    BookingPageMeetingTypeSchema
    |> where([l], l.booking_page_id == ^page_id and l.meeting_type_id == ^meeting_type_id)
    |> Repo.delete_all()

    :ok
  end

  @doc """
  The active meeting types listed on a page, in the host's order, preloaded
  as `MeetingTypeQueries.list_public_meeting_types/1` preloads them.
  """
  @spec list_meeting_types(integer()) :: [MeetingTypeSchema.t()]
  def list_meeting_types(page_id) do
    from(mt in MeetingTypeSchema,
      join: l in BookingPageMeetingTypeSchema,
      on: l.meeting_type_id == mt.id,
      where: l.booking_page_id == ^page_id and mt.is_active == true,
      order_by: [asc: mt.sort_order, asc: mt.name],
      preload: [:video_integration, :calendar_integration]
    )
    |> Repo.all()
  end

  @doc "Every `{meeting_type_id, page_id}` listing among a profile's pages."
  @spec memberships_for_profile(integer()) :: [{integer(), integer()}]
  def memberships_for_profile(profile_id) do
    from(l in BookingPageMeetingTypeSchema,
      join: p in BookingPageSchema,
      on: p.id == l.booking_page_id,
      where: p.profile_id == ^profile_id,
      select: {l.meeting_type_id, l.booking_page_id}
    )
    |> Repo.all()
  end
```

- [ ] **Step 4: Add the context functions**

In `lib/tymeslot/booking_pages.ex`, add the alias `alias Tymeslot.MeetingTypes.GroupAccess` and:

```elixir
  @doc """
  Lists `meeting_type_id` on `page` or takes it off. The caller has checked the
  type is the page owner's.
  """
  @spec set_meeting_type(page(), integer(), boolean()) :: :ok
  def set_meeting_type(%BookingPageSchema{id: page_id}, meeting_type_id, true),
    do: BookingPageQueries.add_meeting_type(page_id, meeting_type_id)

  def set_meeting_type(%BookingPageSchema{id: page_id}, meeting_type_id, false),
    do: BookingPageQueries.remove_meeting_type(page_id, meeting_type_id)

  @doc """
  The meeting types `page` offers on its start page: listed on it, active, and
  not a paused group type, as `MeetingTypes.get_public_meeting_types/1` treats
  the profile's own page.
  """
  @spec list_meeting_types(page()) :: [Tymeslot.MeetingTypes.MeetingTypeSchema.t()]
  def list_meeting_types(%BookingPageSchema{id: page_id}) do
    page_id
    |> BookingPageQueries.list_meeting_types()
    |> GroupAccess.reject_paused()
  end

  @doc """
  Which extra pages each of the profile's meeting types is listed on. A type
  on none of them has no key.
  """
  @spec memberships(integer()) :: %{optional(integer()) => MapSet.t(integer())}
  def memberships(profile_id) do
    profile_id
    |> BookingPageQueries.memberships_for_profile()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {type_id, page_ids} -> {type_id, MapSet.new(page_ids)} end)
  end
```

- [ ] **Step 5: Run the tests**

Run (mix): `test test/tymeslot/booking_pages`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add lib/tymeslot/booking_pages.ex lib/tymeslot/booking_pages/booking_page_queries.ex test/tymeslot/booking_pages/membership_test.exs
git commit -m "feat(booking-pages): list meeting types on booking pages"
```

---
### Task 6: Resolve page addresses and serve the start page

**Files:**
- Modify: `lib/tymeslot/booking_pages.ex`
- Modify: `lib/tymeslot/profiles.ex` (`get_profile_by_username/1`, ~line 122)
- Modify: `lib/tymeslot/profiles/organizer_context.ex`
- Modify: `lib/tymeslot/demo.ex`, `lib/tymeslot/demo/behaviour.ex`, `lib/tymeslot/demo/no_op.ex` (`get_theme_customization/2`)
- Modify: `lib/tymeslot_web/themes/core/context.ex` (`load_customizations/2`)
- Modify: `lib/tymeslot_web/themes/shared/customization/helpers.ex` (`assign_theme_customization/3`)
- Test: `test/tymeslot/booking_pages/resolution_test.exs`
- Test: `test/tymeslot_web/live/booking_page_public_test.exs`

**Interfaces:**
- Consumes: Tasks 1–5.
- Produces (`Tymeslot.BookingPages`):
  - `apply_to_profile(ProfileSchema.t(), page) :: ProfileSchema.t()` — the profile with the page's `booking_theme`, `booking_text_enabled`, `booking_heading`, `booking_greeting`, `booking_instruction` and `booking_page: page`.
  - `profile_for_address(String.t()) :: ProfileSchema.t() | nil` — the overlaid owner profile for a page address.
  - `resolve_with_user(String.t()) :: {:ok, ProfileSchema.t()} | {:error, :not_found}` — the same with `:user` preloaded.
  - `public_address(map() | nil) :: String.t() | nil` — the page's address for an overlaid profile, else its username.
  - `page_id(map() | nil) :: integer() | nil` — the page id of an overlaid profile, else nil.
- Produces: `Profiles.get_profile_by_username/1` answers page addresses with the overlaid owner profile (username first).

- [ ] **Step 1: Write the failing domain test**

```elixir
# test/tymeslot/booking_pages/resolution_test.exs
defmodule Tymeslot.BookingPages.ResolutionTest do
  use Tymeslot.DataCase, async: true

  @moduletag :profiles
  @moduletag :themes

  import Tymeslot.Factory

  alias Tymeslot.BookingPages
  alias Tymeslot.Profiles
  alias TymeslotWeb.Themes.Core.Context
  alias TymeslotWeb.Themes.Shared.Customization.Helpers

  setup do
    profile = insert(:profile, username: "joern", booking_theme: "2")

    page =
      insert(:booking_page,
        profile: profile,
        slug: "einfachiso",
        booking_theme: "1",
        booking_text_enabled: true,
        booking_heading: "ISO consulting",
        booking_greeting: "Hello",
        booking_instruction: "Pick"
      )

    %{profile: profile, page: page}
  end

  test "a page address resolves to its owner, wearing the page", %{profile: profile, page: page} do
    resolved = Profiles.get_profile_by_username("einfachiso")

    assert resolved.id == profile.id
    assert resolved.username == "joern"
    assert resolved.booking_theme == "1"
    assert resolved.booking_heading == "ISO consulting"
    assert resolved.booking_page.id == page.id
    assert BookingPages.public_address(resolved) == "einfachiso"
    assert BookingPages.page_id(resolved) == page.id
  end

  test "a username resolves to the profile as it is" do
    resolved = Profiles.get_profile_by_username("joern")

    assert resolved.booking_theme == "2"
    assert resolved.booking_page == nil
    assert BookingPages.public_address(resolved) == "joern"
    assert BookingPages.page_id(resolved) == nil
  end

  test "a username wins over a page holding the same address" do
    other = insert(:profile, username: "clash")
    # Inserted directly, as a race between the two checks would leave it.
    insert(:booking_page, slug: "clash")

    resolved = Profiles.get_profile_by_username("clash")

    assert resolved.id == other.id
    assert resolved.booking_page == nil
  end

  test "an unknown address resolves to nothing" do
    assert Profiles.get_profile_by_username("nobody-here") == nil
    assert Profiles.resolve_organizer_context("nobody-here") == {:error, :profile_not_found}
  end

  test "the organiser context lists the page's own types", %{profile: profile, page: page} do
    on_page = insert(:meeting_type, user: profile.user, name: "ISO audit")
    insert(:meeting_type, user: profile.user, name: "Automation call")
    :ok = BookingPages.set_meeting_type(page, on_page.id, true)

    assert {:ok, context} = Profiles.resolve_organizer_context("einfachiso")
    assert Enum.map(context.meeting_types, & &1.name) == ["ISO audit"]
    assert context.username == "einfachiso"
    assert context.user_id == profile.user_id
  end

  test "a page with nothing to list offers nothing, not the profile's types", %{profile: profile} do
    insert(:meeting_type, user: profile.user, name: "Automation call")

    assert {:ok, %{meeting_types: []}} = Profiles.resolve_organizer_context("einfachiso")
  end

  test "the start page wears the page's colours", %{profile: profile, page: page} do
    insert(:theme_customization, profile: profile, theme_id: "1", color_scheme: "ocean")

    insert(:theme_customization,
      profile: profile,
      booking_page: page,
      theme_id: "1",
      color_scheme: "rose"
    )

    resolved = Profiles.get_profile_by_username("einfachiso")
    socket = Helpers.assign_theme_customization(%Phoenix.LiveView.Socket{}, resolved, "1")

    assert socket.assigns.theme_customization.color_scheme == "rose"
    assert Context.new("1", resolved).customizations["color_scheme"] == "rose"
    assert Context.new("1", profile).customizations["color_scheme"] == "ocean"
  end
end
```

- [ ] **Step 2: Run it to see it fail**

Run (mix): `test test/tymeslot/booking_pages/resolution_test.exs`
Expected: FAIL — `get_profile_by_username("einfachiso")` returns nil; `BookingPages.public_address/1` is undefined.

- [ ] **Step 3: Add resolution and overlay to the context**

In `lib/tymeslot/booking_pages.ex`, add:

```elixir
  # The page settings a page carries in place of its owner's.
  @page_settings [
    :booking_theme,
    :booking_text_enabled,
    :booking_heading,
    :booking_greeting,
    :booking_instruction
  ]

  @doc """
  `profile` as `page` presents it: the page's theme and booking texts in place
  of the profile's, and the page itself under the virtual `:booking_page`.
  Name, photo, timezone, username and embed domains stay the profile's.

  Everything that renders a start page reads these fields off the profile, so
  it renders the page without knowing pages exist. Never persist the result.
  """
  @spec apply_to_profile(ProfileSchema.t(), page()) :: ProfileSchema.t()
  def apply_to_profile(%ProfileSchema{} = profile, %BookingPageSchema{} = page) do
    profile
    |> struct(Map.take(page, @page_settings))
    |> Map.put(:booking_page, page)
  end

  @doc """
  The owner's profile, as the page at `address` presents it, or nil when no
  page has that address. Callers try usernames first.
  """
  @spec profile_for_address(String.t()) :: ProfileSchema.t() | nil
  def profile_for_address(address) when is_binary(address) do
    case BookingPageQueries.get_by_slug(address, [:profile]) do
      nil -> nil
      page -> apply_to_profile(page.profile, page)
    end
  end

  @doc """
  `profile_for_address/1` with the owner's user preloaded, as the scheduling
  flow's organiser context needs it.
  """
  @spec resolve_with_user(String.t()) :: {:ok, ProfileSchema.t()} | {:error, :not_found}
  def resolve_with_user(address) when is_binary(address) do
    case BookingPageQueries.get_by_slug(address, profile: :user) do
      nil -> {:error, :not_found}
      page -> {:ok, apply_to_profile(page.profile, page)}
    end
  end

  @doc """
  The address a profile's start page is at: its page's for a profile resolved
  through a page, otherwise its username.
  """
  @spec public_address(map() | nil) :: String.t() | nil
  def public_address(%{booking_page: %BookingPageSchema{slug: slug}}), do: slug
  def public_address(%{username: username}), do: username
  def public_address(_no_profile), do: nil

  @doc "The page a profile was resolved through, by id, or nil."
  @spec page_id(map() | nil) :: integer() | nil
  def page_id(%{booking_page: %BookingPageSchema{id: id}}), do: id
  def page_id(_profile), do: nil
```

- [ ] **Step 4: Let the username lookup fall back to page addresses**

In `lib/tymeslot/profiles.ex`, add `alias Tymeslot.BookingPages` to the aliases, and replace `get_profile_by_username/1` and its `@doc`:

```elixir
  @doc """
  Resolves a public address to a profile: a username, or failing that one of
  its booking pages' addresses, which answers with the owner's profile as that
  page presents it (`Tymeslot.BookingPages.apply_to_profile/2`). A username
  always wins, so a page can never take over another host's start page.
  """
  @spec get_profile_by_username(username) :: profile | nil
  def get_profile_by_username(username) do
    case ProfileQueries.get_by_username(username) do
      {:ok, profile} -> profile
      {:error, :not_found} -> BookingPages.profile_for_address(username)
    end
  end
```

- [ ] **Step 5: Resolve pages in the organiser context**

In `lib/tymeslot/profiles/organizer_context.ex`, add aliases:

```elixir
  alias Tymeslot.BookingPages
  alias Tymeslot.BookingPages.BookingPageSchema
```

Replace `resolve_organizer_context/1` and `load_active_meeting_types/1` with:

```elixir
  def resolve_organizer_context(username) when is_binary(username) do
    case resolve_profile(username) do
      {:ok, profile} ->
        meeting_types = load_meeting_types(profile)
        profile_with_meeting_types = %{profile | meeting_types: meeting_types}
        {:ok, build_organizer_context(profile_with_meeting_types, username)}

      {:error, :not_found} ->
        {:error, :profile_not_found}
    end
  end

  # A username first, then a booking page's address: a username always wins.
  defp resolve_profile(address) do
    case ProfileQueries.get_by_username_with_user(address) do
      {:ok, profile} -> {:ok, profile}
      {:error, :not_found} -> BookingPages.resolve_with_user(address)
    end
  end

  defp load_meeting_types(%{booking_page: %BookingPageSchema{} = page}),
    do: BookingPages.list_meeting_types(page)

  defp load_meeting_types(profile), do: MeetingTypes.get_public_meeting_types(profile.user_id)
```

and add this clause **above** the existing `meeting_types_for_profile/1`:

```elixir
  # A booking page lists exactly its own types; an empty list is its empty
  # state, never a reason to show the profile's.
  defp meeting_types_for_profile(%{booking_page: %BookingPageSchema{}, meeting_types: types}),
    do: types
```

- [ ] **Step 6: Load a page's colours on the public page**

In `lib/tymeslot_web/themes/core/context.ex`, add this clause directly **above** `defp load_customizations(theme_id, profile) do`:

```elixir
  defp load_customizations(theme_id, %{booking_page: %{id: _page_id}} = profile) do
    case ThemeCustomizations.get_by_profile_and_theme(
           ThemeCustomizations.scope_for(profile),
           theme_id
         ) do
      nil -> ThemeCustomizations.get_defaults(theme_id)
      customization -> ThemeCustomizations.to_map(customization)
    end
  end
```

In `lib/tymeslot_web/themes/shared/customization/helpers.ex`, in `assign_theme_customization/3`, replace

```elixir
    customization = Demo.get_theme_customization(profile.id, theme_id)
```

with

```elixir
    customization =
      Demo.get_theme_customization(ThemeCustomizations.scope_for(profile), theme_id)
```

Widen the demo seam to accept a scope. In `lib/tymeslot/demo/behaviour.ex`:

```elixir
  @callback get_theme_customization(
              scope :: integer() | {integer(), integer()},
              theme_id :: String.t()
            ) :: any()
```

In `lib/tymeslot/demo.ex`:

```elixir
  @spec get_theme_customization(integer() | {integer(), integer()}, String.t()) :: any()
  def get_theme_customization(scope, theme_id),
    do: provider().get_theme_customization(scope, theme_id)
```

In `lib/tymeslot/demo/no_op.ex`:

```elixir
  @impl Tymeslot.Demo.Behaviour
  def get_theme_customization(scope, theme_id)
      when (is_integer(scope) or is_tuple(scope)) and is_binary(theme_id) do
    ThemeCustomizations.get_by_profile_and_theme(scope, theme_id)
  end
```

- [ ] **Step 7: Run the domain test**

Run (mix): `test test/tymeslot/booking_pages/resolution_test.exs`
Expected: 7 tests, 0 failures.

- [ ] **Step 8: Write the LiveView test**

```elixir
# test/tymeslot_web/live/booking_page_public_test.exs
defmodule TymeslotWeb.BookingPagePublicTest do
  @moduledoc """
  The public side of booking pages: a page's start page, the flow under its
  address, and the profile's own page left as it was.
  """
  use TymeslotWeb.LiveCase, async: false
  @moduletag :scheduling

  import Mox
  import Phoenix.ConnTest
  import Tymeslot.Factory

  alias Tymeslot.BookingPages
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()
    :ok
  end

  @timezone "America/New_York"

  setup do
    user = insert(:user)
    profile = insert(:profile, user: user, username: "joern", booking_theme: "1", timezone: @timezone)

    schedule =
      insert(:availability_schedule,
        profile: profile,
        is_default: true,
        advance_booking_days: 30,
        min_advance_hours: 0,
        buffer_before_minutes: 0,
        buffer_after_minutes: 0
      )

    Enum.each(1..7, fn day_of_week ->
      insert(:weekly_availability,
        schedule: schedule,
        day_of_week: day_of_week,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )
    end)

    insert(:calendar_integration, user: user, is_active: true)

    page =
      insert(:booking_page,
        profile: profile,
        slug: "einfachiso",
        name: "einfachISO",
        booking_text_enabled: true,
        booking_heading: "ISO consulting",
        booking_greeting: "Hello from einfachISO",
        booking_instruction: "Choose a session"
      )

    audit = insert(:meeting_type, user: user, name: "ISO audit", duration_minutes: 30)
    insert(:meeting_type, user: user, name: "Automation call", duration_minutes: 30)
    :ok = BookingPages.set_meeting_type(page, audit.id, true)

    %{user: user, profile: profile, page: page}
  end

  test "a page shows its own texts and meeting types", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/einfachiso?timezone=#{@timezone}")

    assert html =~ "ISO consulting"
    assert html =~ "Choose a session"
    assert html =~ "ISO audit"
    refute html =~ "Automation call"
  end

  test "the username's page is as it was", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/joern?timezone=#{@timezone}")

    refute html =~ "ISO consulting"
    assert html =~ "ISO audit"
    assert html =~ "Automation call"
  end

  test "a page with nothing listed shows the empty state", %{conn: conn, profile: profile} do
    insert(:booking_page, profile: profile, slug: "empty-page")

    {:ok, _view, html} = live(conn, ~p"/empty-page?timezone=#{@timezone}")

    assert html =~ "No meeting types available"
    refute html =~ "Automation call"
  end

  test "links inside the flow stay under the page's address", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/einfachiso/iso-audit?timezone=#{@timezone}")

    assert has_element?(view, "button[phx-click='next_month']")

    # The language switcher rebuilds the current step's path the same way the
    # flow's own links do (`PathHandlers`), so it shows where they lead.
    assert {:error, {:redirect, %{to: to}}} =
             render_hook(view, "change_locale", %{"locale" => "de"})

    assert URI.parse(to).path == "/einfachiso/iso-audit"
  end

  test "an unknown address is a 404", %{conn: conn} do
    assert_error_sent 404, fn -> get(conn, "/no-such-page-here") end
  end

  test "a page address may be framed on its owner's embed domains", %{conn: conn, profile: profile} do
    profile
    |> Ecto.Changeset.change(allowed_embed_domains: ["einfachiso.de"])
    |> Tymeslot.Repo.update!()

    conn = get(conn, "/einfachiso")

    assert [csp] = Plug.Conn.get_resp_header(conn, "content-security-policy")
    assert csp =~ "einfachiso.de"
  end
end
```

- [ ] **Step 9: Run it**

Run (mix): `test test/tymeslot_web/live/booking_page_public_test.exs`
Expected: 6 tests, 0 failures. If `render_hook` answers `{:error, {:live_redirect, …}}` instead, the locale switch navigates inside the LiveView on this version: match `{:error, {_kind, %{to: to}}}` and keep the path assertion.

- [ ] **Step 10: Run the neighbouring suites**

Run (mix): `test test/tymeslot/profiles test/tymeslot_web/live/private_booking_test.exs test/tymeslot_web/live/themes test/tymeslot_web/themes test/tymeslot/demo`
Expected: all pass.

- [ ] **Step 11: Commit**

```bash
git add lib/tymeslot/booking_pages.ex lib/tymeslot/profiles.ex lib/tymeslot/profiles/organizer_context.ex \
  lib/tymeslot/demo.ex lib/tymeslot/demo/behaviour.ex lib/tymeslot/demo/no_op.ex \
  lib/tymeslot_web/themes/core/context.ex lib/tymeslot_web/themes/shared/customization/helpers.ex \
  test/tymeslot/booking_pages/resolution_test.exs test/tymeslot_web/live/booking_page_public_test.exs
git commit -m "feat(booking-pages): serve booking pages at their own addresses"
```

---

### Task 7: Bookings remember their page

**Files:**
- Modify: `lib/tymeslot/booking_pages.ex`
- Modify: `lib/tymeslot_web/live/scheduling/handlers/booking_submission_handler_component.ex` (`build_meeting_params/2`, ~line 374)
- Modify: `lib/tymeslot/bookings/create.ex` (`booking_data` map, ~line 180)
- Modify: `lib/tymeslot/bookings/build_params.ex`
- Modify: `lib/tymeslot/bookings/policy.ex` (`@type meeting_attributes` ~line 136, `scheduling_config/2` ~line 68, `source_attribution/1` ~line 291)
- Modify: `lib/tymeslot_web/themes/shared/path_handlers.ex` (`organizer_scheduling_path/1`)
- Test: `test/tymeslot_web/live/booking_page_booking_test.exs`
- Test: `test/tymeslot/booking_pages/attribution_test.exs`

**Interfaces:**
- Consumes: `BookingPages.page_id/1`, `public_address/1` (Task 6).
- Produces: `BookingPages.existing_id(integer() | nil) :: integer() | nil`.
- Produces: `MeetingSchema.booking_page_id` filled for bookings made under a page address.
- Produces: `PathHandlers.organizer_scheduling_path/1` returns the page address for an overlaid organiser profile.

- [ ] **Step 1: Write the failing tests**

```elixir
# test/tymeslot/booking_pages/attribution_test.exs
defmodule Tymeslot.BookingPages.AttributionTest do
  use Tymeslot.DataCase, async: true

  @moduletag :bookings

  import Tymeslot.Factory

  alias Tymeslot.BookingPages
  alias TymeslotWeb.Themes.Shared.PathHandlers

  test "existing_id/1 keeps a live page's id and drops a deleted one's" do
    page = insert(:booking_page)

    assert BookingPages.existing_id(page.id) == page.id
    assert BookingPages.existing_id(nil) == nil

    {:ok, _deleted} = BookingPages.delete(page)
    assert BookingPages.existing_id(page.id) == nil
  end

  test "choosing a new time returns to the page the booking belongs to" do
    profile = insert(:profile, username: "joern")
    page = insert(:booking_page, profile: profile, slug: "einfachiso")

    assert PathHandlers.organizer_scheduling_path(%{organizer_profile: profile}) == "/joern"

    assert PathHandlers.organizer_scheduling_path(%{
             organizer_profile: BookingPages.apply_to_profile(profile, page),
             meeting_uid: "abc"
           }) == "/einfachiso?reschedule_meeting_uid=abc"
  end
end
```

```elixir
# test/tymeslot_web/live/booking_page_booking_test.exs
defmodule TymeslotWeb.BookingPageBookingTest do
  use TymeslotWeb.LiveCase, async: false
  @moduletag :bookings
  @moduletag :scheduling

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.BookingPages
  alias Tymeslot.BookingTestHelpers
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()
    :ok
  end

  @timezone "America/New_York"

  setup do
    user = insert(:user)
    profile = insert(:profile, user: user, username: "joern", booking_theme: "1", timezone: @timezone)

    schedule =
      insert(:availability_schedule,
        profile: profile,
        is_default: true,
        advance_booking_days: 30,
        min_advance_hours: 0,
        buffer_before_minutes: 0,
        buffer_after_minutes: 0
      )

    Enum.each(1..7, fn day_of_week ->
      insert(:weekly_availability,
        schedule: schedule,
        day_of_week: day_of_week,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )
    end)

    insert(:calendar_integration, user: user, is_active: true)
    page = insert(:booking_page, profile: profile, slug: "einfachiso")
    audit = insert(:meeting_type, user: user, name: "ISO audit", duration_minutes: 30)
    :ok = BookingPages.set_meeting_type(page, audit.id, true)

    %{user: user, page: page}
  end

  @tag :capture_log
  test "a booking made under a page records the page", %{conn: conn, user: user, page: page} do
    {:ok, view, _html} = live(conn, ~p"/einfachiso/iso-audit?timezone=#{@timezone}")
    book_first_slot(view, "page-booker@example.com")
    wait_until(fn -> render(view) =~ "Meeting Confirmed!" end)

    meeting =
      Repo.get_by!(MeetingSchema,
        organizer_user_id: user.id,
        attendee_email: "page-booker@example.com"
      )

    assert meeting.booking_page_id == page.id
  end

  @tag :capture_log
  test "a booking made under the username records no page", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/joern/iso-audit?timezone=#{@timezone}")
    book_first_slot(view, "username-booker@example.com")
    wait_until(fn -> render(view) =~ "Meeting Confirmed!" end)

    meeting =
      Repo.get_by!(MeetingSchema,
        organizer_user_id: user.id,
        attendee_email: "username-booker@example.com"
      )

    assert meeting.booking_page_id == nil
  end

  # Same driver as `TymeslotWeb.PrivateBookingTest`.
  defp book_first_slot(view, attendee_email) do
    target_date = @timezone |> DateTime.now!() |> DateTime.to_date() |> Date.add(1)
    BookingTestHelpers.show_month(view, target_date)
    date_str = Date.to_string(target_date)

    wait_until(fn ->
      has_element?(view, "button.calendar-day[phx-value-date='#{date_str}']:not([disabled])")
    end)

    view |> element("button.calendar-day[phx-value-date='#{date_str}']") |> render_click()
    wait_until(fn -> has_element?(view, "button.time-slot-button") end)

    slot =
      view
      |> render()
      |> Floki.parse_document!()
      |> Floki.attribute("button.time-slot-button", "phx-value-time")
      |> List.first()

    view |> element("button.time-slot-button[phx-value-time='#{slot}']") |> render_click()
    view |> element("button[phx-click='next_step']") |> render_click()

    view
    |> form("form[phx-submit='submit']", %{
      "booking" => %{"name" => "Test Attendee", "email" => attendee_email, "message" => "Hi"}
    })
    |> render_submit()
  end
end
```

- [ ] **Step 2: Run them to see them fail**

Run (mix): `test test/tymeslot/booking_pages/attribution_test.exs test/tymeslot_web/live/booking_page_booking_test.exs`
Expected: FAIL — `existing_id/1` undefined; the page booking records `booking_page_id: nil`; the reschedule path is `/joern?…`.

- [ ] **Step 3: Add `existing_id/1`**

In `lib/tymeslot/booking_pages.ex`:

```elixir
  @doc """
  `id` when that page still exists, otherwise nil. A booking keeps the page it
  came through only while there is one: a page deleted while its visitor was
  on the booking form must not make the booking fail.
  """
  @spec existing_id(integer() | nil) :: integer() | nil
  def existing_id(id) when is_integer(id),
    do: if(BookingPageQueries.exists?(id), do: id, else: nil)

  def existing_id(_none), do: nil
```

- [ ] **Step 4: Carry the page id from the form to the meeting**

In `booking_submission_handler_component.ex`, add `alias Tymeslot.BookingPages` to the aliases and, in `build_meeting_params/2`, after `meeting_type_id: get_meeting_type_id(socket),` add:

```elixir
      booking_page_id: BookingPages.page_id(socket.assigns[:organizer_profile]),
```

In `lib/tymeslot/bookings/create.ex`, add `alias Tymeslot.BookingPages` and, in the `booking_data` map after `visitor_hash: Map.get(meeting_params, :visitor_hash)`, change that line to end with a comma and add:

```elixir
        booking_page_id: BookingPages.existing_id(Map.get(meeting_params, :booking_page_id))
```

In `lib/tymeslot/bookings/build_params.ex`, add `:booking_page_id,` to `defstruct` after `:visitor_hash,`, and `booking_page_id: integer() | nil,` to `@type t` after `visitor_hash: String.t() | nil,`.

In `lib/tymeslot/bookings/policy.ex` (keep the file at or under 650 lines):

1. In `@type meeting_attributes`, change `required(:visitor_hash) => String.t() | nil` to end with a comma and add `required(:booking_page_id) => integer() | nil` after it.
2. In `source_attribution/1`, change `visitor_hash: params.visitor_hash` to end with a comma and add `booking_page_id: params.booking_page_id` after it.
3. In `scheduling_config/2`, delete the two comment lines directly above `|> Map.put(:profile_id, settings.profile_id)`:

```elixir
    # No date is in scope here, so trips are not prefetched: the slot engine
    # loads them from this id for the dates it reads (`Calculate`).
```

Check: `wc -l lib/tymeslot/bookings/policy.ex` prints 649.

- [ ] **Step 5: Return reschedules to the page**

In `lib/tymeslot_web/themes/shared/path_handlers.ex`, add `alias Tymeslot.BookingPages` and replace the body of `organizer_scheduling_path/1`:

```elixir
  def organizer_scheduling_path(assigns) do
    case BookingPages.public_address(assigns[:organizer_profile]) do
      address when is_binary(address) and address != "" ->
        maybe_append_reschedule_uid("/#{address}", assigns[:meeting_uid])

      _other ->
        "/"
    end
  end
```

Update its `@doc` example line from `e.g. "/username"` to `e.g. "/username", or the booking page's address for an organiser resolved through one`.

- [ ] **Step 6: Run the tests**

Run (mix): `test test/tymeslot/booking_pages/attribution_test.exs test/tymeslot_web/live/booking_page_booking_test.exs test/tymeslot/bookings test/tymeslot_web/themes`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add lib/tymeslot/booking_pages.ex lib/tymeslot/bookings/ lib/tymeslot_web/themes/shared/path_handlers.ex \
  lib/tymeslot_web/live/scheduling/handlers/booking_submission_handler_component.ex \
  test/tymeslot/booking_pages/attribution_test.exs test/tymeslot_web/live/booking_page_booking_test.exs
git commit -m "feat(booking-pages): record the page a booking came through"
```

---

### Task 8: Managing a booking, and emails, follow its page

**Files:**
- Modify: `lib/tymeslot/booking_pages.ex`
- Modify: `lib/tymeslot_web/themes/core/mount_helpers.ex` (`mount_meeting_management/4`)
- Modify: `lib/tymeslot/emails/appointment_builder.ex` (`url_details/2`, ~line 293)
- Test: `test/tymeslot_web/live/booking_page_meeting_management_test.exs`
- Test: `test/tymeslot/emails/appointment_builder_booking_page_test.exs`

**Interfaces:**
- Consumes: `apply_to_profile/2` (Task 6), `MeetingSchema.booking_page_id` (Task 1).
- Produces: `BookingPages.for_meeting(ProfileSchema.t(), map()) :: ProfileSchema.t()` — the profile as the meeting's page presents it while that page exists, else unchanged.
- Produces: `BookingPages.address_for_meeting(map(), String.t() | nil) :: String.t() | nil` — the meeting's page address while it exists, else the fallback.

- [ ] **Step 1: Write the failing tests**

```elixir
# test/tymeslot_web/live/booking_page_meeting_management_test.exs
defmodule TymeslotWeb.BookingPageMeetingManagementTest do
  use TymeslotWeb.LiveCase, async: true
  @moduletag :scheduling

  import Tymeslot.Factory

  alias Tymeslot.BookingPages

  setup do
    user = insert(:user)
    profile = insert(:profile, user: user, username: "joern", booking_theme: "2")
    page = insert(:booking_page, profile: profile, slug: "einfachiso", booking_theme: "1")
    insert(:theme_customization, profile: profile, theme_id: "2", color_scheme: "ocean")

    insert(:theme_customization,
      profile: profile,
      booking_page: page,
      theme_id: "1",
      color_scheme: "rose"
    )

    start_time = DateTime.utc_now() |> DateTime.add(86_400) |> DateTime.truncate(:second)

    meeting =
      insert(:meeting,
        organizer_user: user,
        status: "confirmed",
        start_time: start_time,
        end_time: DateTime.add(start_time, 1800),
        booking_page_id: page.id
      )

    %{profile: profile, page: page, meeting: meeting}
  end

  defp assigns_of(view), do: :sys.get_state(view.pid).socket.assigns

  test "the cancel page of a page's booking wears the page", %{conn: conn, meeting: meeting} do
    {:ok, view, _html} = live(conn, ~p"/joern/meeting/#{meeting.uid}/cancel")

    assert assigns_of(view).theme_id == "1"
    assert assigns_of(view).theme_customization.color_scheme == "rose"
  end

  test "once the page is gone, the profile's look returns", %{conn: conn, page: page, meeting: meeting} do
    {:ok, _deleted} = BookingPages.delete(page)

    {:ok, view, _html} = live(conn, ~p"/joern/meeting/#{meeting.uid}/cancel")

    assert assigns_of(view).theme_id == "2"
    assert assigns_of(view).theme_customization.color_scheme == "ocean"
  end
end
```

```elixir
# test/tymeslot/emails/appointment_builder_booking_page_test.exs
defmodule Tymeslot.Emails.AppointmentBuilderBookingPageTest do
  use Tymeslot.DataCase, async: true

  @moduletag :emails

  import Tymeslot.Factory

  alias Tymeslot.BookingPages
  alias Tymeslot.Emails.AppointmentBuilder

  setup do
    user = insert(:user)
    profile = insert(:profile, user: user, username: "joern")
    page = insert(:booking_page, profile: profile, slug: "einfachiso")
    %{user: user, page: page}
  end

  defp meeting(user, attrs) do
    insert(:meeting,
      Keyword.merge(
        [
          organizer_user_id: user.id,
          start_time: ~U[2027-03-17 14:00:00Z],
          end_time: ~U[2027-03-17 15:00:00Z]
        ],
        attrs
      )
    )
  end

  test "\"book another time\" leads to the page the booking came through", %{user: user, page: page} do
    result = AppointmentBuilder.from_meeting(meeting(user, booking_page_id: page.id))

    assert URI.parse(result.booking_url).path == "/einfachiso"
  end

  test "it leads to the username once the page is gone", %{user: user, page: page} do
    booked = meeting(user, booking_page_id: page.id)
    {:ok, _deleted} = BookingPages.delete(page)

    result = AppointmentBuilder.from_meeting(%{booked | booking_page_id: nil})

    assert URI.parse(result.booking_url).path == "/joern"
  end
end
```

- [ ] **Step 2: Run them to see them fail**

Run (mix): `test test/tymeslot_web/live/booking_page_meeting_management_test.exs test/tymeslot/emails/appointment_builder_booking_page_test.exs`
Expected: FAIL — the cancel page uses theme `"2"`; the booking URL path is `/joern`.

- [ ] **Step 3: Add the meeting helpers**

In `lib/tymeslot/booking_pages.ex`:

```elixir
  @doc """
  `profile` as the page `meeting` was booked through presents it, while that
  page exists; otherwise `profile` unchanged. Managing a booking (cancel,
  reschedule) happens in the look the booking was made in, whichever address
  the link came in on.
  """
  @spec for_meeting(ProfileSchema.t(), map()) :: ProfileSchema.t()
  def for_meeting(%ProfileSchema{} = profile, %{booking_page_id: page_id})
      when is_integer(page_id) do
    case BookingPageQueries.get_for_profile(profile.id, page_id) do
      nil -> profile
      page -> apply_to_profile(profile, page)
    end
  end

  def for_meeting(profile, _meeting), do: profile

  @doc """
  The address to send someone back to for `meeting`: its page's while the
  page exists, otherwise `fallback` (the host's username).
  """
  @spec address_for_meeting(map(), String.t() | nil) :: String.t() | nil
  def address_for_meeting(%{booking_page_id: page_id}, fallback) when is_integer(page_id) do
    case BookingPageQueries.get(page_id) do
      %BookingPageSchema{slug: slug} -> slug
      nil -> fallback
    end
  end

  def address_for_meeting(_meeting, fallback), do: fallback
```

- [ ] **Step 4: Manage a booking in its page's look**

In `lib/tymeslot_web/themes/core/mount_helpers.ex`, add `alias Tymeslot.BookingPages`, and in `mount_meeting_management/4` replace

```elixir
    theme_id = profile.booking_theme || socket.assigns[:theme_id] || Registry.default_theme_id()
    meeting_uid = params["meeting_uid"]

    case MeetingManagement.validate_and_load_meeting(meeting_uid, action, profile.user_id) do
      {:ok, meeting} ->
        socket =
```

with

```elixir
    meeting_uid = params["meeting_uid"]

    case MeetingManagement.validate_and_load_meeting(meeting_uid, action, profile.user_id) do
      {:ok, meeting} ->
        # A booking made through a booking page is managed in that page's look.
        profile = BookingPages.for_meeting(profile, meeting)

        theme_id =
          profile.booking_theme || socket.assigns[:theme_id] || Registry.default_theme_id()

        socket =
```

- [ ] **Step 5: Point "book another time" at the page**

In `lib/tymeslot/emails/appointment_builder.ex`, add `alias Tymeslot.BookingPages` and in `url_details/2` replace

```elixir
      # The host's public booking page, resolved at send time rather than read
      # from the meeting row. Unlike the per-meeting action URLs it is not
      # persisted, so it always reflects the host's current username.
      booking_url: UrlBuilder.booking_url(organizer_profile && organizer_profile.username),
```

with

```elixir
      # The host's public booking page, resolved at send time rather than read
      # from the meeting row: the booking page the meeting came through while
      # that page exists, else the host's current username.
      booking_url:
        UrlBuilder.booking_url(
          BookingPages.address_for_meeting(
            meeting,
            organizer_profile && organizer_profile.username
          )
        ),
```

- [ ] **Step 6: Run the tests**

Run (mix): `test test/tymeslot_web/live/booking_page_meeting_management_test.exs test/tymeslot/emails/appointment_builder_booking_page_test.exs test/tymeslot/emails test/tymeslot_web/live/themes/meeting_idor_test.exs`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add lib/tymeslot/booking_pages.ex lib/tymeslot_web/themes/core/mount_helpers.ex lib/tymeslot/emails/appointment_builder.ex \
  test/tymeslot_web/live/booking_page_meeting_management_test.exs test/tymeslot/emails/appointment_builder_booking_page_test.exs
git commit -m "feat(booking-pages): manage bookings and send rebook links in their page's look"
```

---
### Task 9: The Theme screen edits the selected page

**Files:**
- Modify (full replacement below): `lib/tymeslot_web/live/dashboard/theme_settings_component.ex`
- Modify: `lib/tymeslot_web/live/dashboard/theme_settings/booking_text_form.ex` (`save/2` ~line 390, `preview_url/2` ~line 456)
- Modify: `lib/tymeslot_web/live/dashboard/theme_settings/theme_customization_component.ex`
- Modify: `lib/tymeslot_web/live/dashboard/theme_settings/background_uploads.ex` (`apply_result/2` ~line 136)
- Modify: `lib/tymeslot_web/helpers/theme_upload_helper.ex`
- Modify: `lib/tymeslot_web/live/dashboard/theme_settings/theme_customization/components.ex` (toolbar preview link ~line 39)
- Test: `test/tymeslot_web/live/dashboard/booking_pages_theme_test.exs`

**Interfaces:**
- Consumes: `BookingPages.list/1`, `apply_to_profile/2`, `public_address/1`, `update_theme/2`, `update_booking_text/2` (Tasks 3, 6); `ThemeCustomizations.scope_for/1` (Task 2).
- Produces: the Theme screen reads `?page=<id>` and assigns `@pages`, `@selected_page` (a page or nil) and `@page_profile` (the profile as the selected page presents it). Component ids gain a `-<page id>` suffix on a page's tab and keep their current ids on the profile's own tab: `booking-text-form`, `theme-customization-<theme>-<timestamp>`.
- Produces: `ThemeSettingsComponent.theme_path(page | nil) :: String.t()` (`/dashboard/theme`, with `?page=<id>` for a page), used by Task 10.

- [ ] **Step 1: Write the failing test**

```elixir
# test/tymeslot_web/live/dashboard/booking_pages_theme_test.exs
defmodule TymeslotWeb.Dashboard.BookingPagesThemeTest do
  use TymeslotWeb.LiveCase, async: true

  @moduletag :themes
  @moduletag :dashboard

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Repo
  alias Tymeslot.ThemeCustomizations

  setup :setup_dashboard_user_with_theme

  setup %{profile: profile} do
    profile = profile |> Ecto.Changeset.change(username: "joern") |> Repo.update!()
    page = insert(:booking_page, profile: profile, slug: "einfachiso", booking_theme: "1")
    %{profile: profile, page: page}
  end

  test "selecting a theme on a page's tab changes only the page", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/theme?#{[page: ctx.page.id]}")

    view |> element("[phx-click='select_theme'][phx-value-theme='2']") |> render_click()

    assert Repo.reload!(ctx.page).booking_theme == "2"
    assert Repo.reload!(ctx.profile).booking_theme == "1"
    # The dashboard keeps the profile's own look: no overlaid profile reached it.
    assert :sys.get_state(view.pid).socket.assigns.profile.booking_page == nil
  end

  test "switching booking texts on for a page writes them to the page", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/theme?#{[page: ctx.page.id]}")

    view |> element("#booking-text-form-#{ctx.page.id}-enabled") |> render_click()

    assert Repo.reload!(ctx.page).booking_text_enabled
    refute Repo.reload!(ctx.profile).booking_text_enabled
  end

  test "the colour editor on a page's tab edits the page's colours", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/theme/customize/1?#{[page: ctx.page.id]}")

    assert render(view) =~ "/einfachiso"

    view
    |> element("[phx-click='theme:select_color_scheme'][phx-value-scheme='purple']")
    |> render_click()

    assert %{color_scheme: "purple"} =
             ThemeCustomizations.get_by_profile_and_theme({ctx.profile.id, ctx.page.id}, "1")

    assert ThemeCustomizations.get_by_profile_and_theme(ctx.profile.id, "1") == nil
  end

  test "closing the colour editor returns to the page's tab", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/theme/customize/1?#{[page: ctx.page.id]}")

    view |> element("[phx-click='close_customization']") |> render_click()

    assert_patch(view, ~p"/dashboard/theme?#{[page: ctx.page.id]}")
  end

  test "the username's tab still edits the profile", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/theme")

    view |> element("[phx-click='select_theme'][phx-value-theme='2']") |> render_click()

    assert Repo.reload!(ctx.profile).booking_theme == "2"
    assert Repo.reload!(ctx.page).booking_theme == "1"
  end
end
```

- [ ] **Step 2: Run it to see it fail**

Run (mix): `test test/tymeslot_web/live/dashboard/booking_pages_theme_test.exs`
Expected: FAIL — the page's tab still edits the profile (`booking_theme` changes on the profile; no `#booking-text-form-<id>-enabled` element).

- [ ] **Step 3: Replace the Theme screen component**

Replace the whole of `lib/tymeslot_web/live/dashboard/theme_settings_component.ex` with:

```elixir
defmodule TymeslotWeb.Dashboard.ThemeSettingsComponent do
  @moduledoc """
  Theme selection component for the dashboard.
  Allows users to select their booking page theme.

  Everything here applies to the page chosen by the `page` query parameter
  (`/dashboard/theme?page=<id>`), or to the profile's own page at
  `/<username>` without one. A booking page is edited through the owner's
  profile as that page presents it (`BookingPages.apply_to_profile/2`, held in
  `@page_profile`), so the theme cards, booking texts and colour editor read
  the page's values unchanged; only the writes branch on whether a page is
  selected.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.BookingPages
  alias Tymeslot.Profiles
  alias Tymeslot.Scheduling.LinkAccessPolicy
  alias TymeslotWeb.Dashboard.ThemeSettings.BookingTextForm
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomizationComponent
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemePreview
  alias TymeslotWeb.Live.Scheduling.PreviewMode
  alias TymeslotWeb.Live.Shared.Flash
  alias TymeslotWeb.Themes.Core.ThemeInfo

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok, socket}
  end

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    params = assigns[:params] || %{}

    customization_theme_id =
      if assigns.live_action == :theme_customization do
        theme_id = params["theme_id"]
        if ThemeInfo.valid_theme_id?(theme_id), do: theme_id, else: nil
      else
        assigns[:customization_theme_id]
      end

    show_customization =
      (assigns.live_action == :theme_customization && not is_nil(customization_theme_id)) ||
        assigns[:show_customization] || false

    pages = BookingPages.list(assigns.profile.id)
    selected_page = Enum.find(pages, &(to_string(&1.id) == params["page"]))

    socket =
      socket
      |> assign(assigns)
      |> assign(:themes, ThemeInfo.theme_options())
      |> assign(:show_customization, show_customization)
      |> assign(:customization_theme_id, customization_theme_id)
      |> assign(:pages, pages)
      |> assign(:selected_page, selected_page)
      |> assign(:page_profile, page_profile(assigns.profile, selected_page))
      |> assign_new(:customization_timestamp, fn -> System.system_time() end)

    {:ok, socket}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div>
      <.dashboard_page icon="hero-paint-brush" title={dgettext("dashboard_common", "Theme")}>
        <%= if @show_customization && @customization_theme_id do %>
          <div class="animate-in fade-in slide-in-from-bottom-4 duration-500">
            <p :if={@pages != []} class="mb-6 text-token-sm font-semibold text-tymeslot-600">
              {dgettext("dashboard_appearance", "You are editing %{address}",
                address: "/" <> (BookingPages.public_address(@page_profile) || "")
              )}
            </p>
            <.live_component
              module={ThemeCustomizationComponent}
              id={
                "theme-customization-#{@customization_theme_id}-#{@customization_timestamp}" <>
                  page_suffix(@selected_page)
              }
              profile={@page_profile}
              theme_id={@customization_theme_id}
              parent_component={@myself}
            />
          </div>
        <% else %>
          <div class="mb-16 max-w-2xl">
            <p class="text-xl text-tymeslot-500 font-medium leading-relaxed">
              {dgettext(
                "dashboard_appearance",
                "Select the interface that best represents your personal brand and creates the best experience for your clients."
              )}
            </p>
          </div>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-10">
            <%= for {theme_name, theme_id} <- @themes do %>
              <div class="group/theme space-y-6">
                <.card
                  padding={:none}
                  interactive
                  class={[
                    "overflow-hidden duration-500",
                    if(@page_profile.booking_theme == theme_id,
                      do:
                        "glass-gradient border-turquoise-400 shadow-turquoise-500/20 ring-4 ring-turquoise-50",
                      else: "hover:border-turquoise-200 hover:shadow-tymeslot-200/50"
                    )
                  ]}
                  phx-click="select_theme"
                  phx-value-theme={theme_id}
                  phx-target={@myself}
                >
                  <div class="h-64 relative overflow-hidden">
                    <ThemePreview.render theme_id={theme_id} />

                    <div class="absolute inset-0 bg-linear-to-t from-tymeslot-900/60 via-transparent to-transparent opacity-60 group-hover/theme:opacity-40 transition-opacity">
                    </div>

                    <div class="absolute bottom-6 left-6 right-6 flex items-center justify-between">
                      <h2 class="text-token-lg font-semibold text-white drop-shadow-md">
                        {theme_name}
                      </h2>
                      <%= if @page_profile.booking_theme == theme_id do %>
                        <.pill tone={:brand} size={:sm} icon="hero-check">
                          {dgettext("dashboard_appearance", "Current style")}
                        </.pill>
                      <% end %>
                    </div>

                    <div
                      :if={!LinkAccessPolicy.can_link?(@profile, @integration_status)}
                      class="absolute inset-0 bg-tymeslot-900/40 backdrop-blur-[2px] flex flex-col items-center justify-center cursor-not-allowed z-20"
                    >
                      <div class="w-12 h-12 bg-white/20 rounded-token-2xl flex items-center justify-center mb-3">
                        <.icon name="hero-lock-closed" class="w-6 h-6 text-white" />
                      </div>
                      <span class="text-white font-black text-token-xs uppercase tracking-widest">
                        {dgettext("dashboard_appearance", "Connect Calendar to Preview")}
                      </span>
                    </div>
                  </div>

                  <div class="p-8">
                    <p class="text-tymeslot-600 font-medium leading-relaxed line-clamp-2">
                      {ThemeInfo.get_description(theme_id)}
                    </p>
                  </div>
                </.card>

                <%!-- Wraps rather than overflows when a narrow card cannot fit both
                    labels on one line. --%>
                <div class="flex flex-wrap gap-4">
                  <%= if LinkAccessPolicy.can_link?(@profile, @integration_status) do %>
                    <.action_link
                      href={
                        PreviewMode.owner_path(
                          BookingPages.public_address(@page_profile),
                          @profile.user_id,
                          theme: theme_id
                        )
                      }
                      target="_blank"
                      rel="noopener noreferrer"
                      variant={:secondary}
                      icon="hero-eye"
                      class="flex-1"
                    >
                      {dgettext("dashboard_appearance", "Live Preview")}
                    </.action_link>
                  <% else %>
                    <%!-- `aria-disabled` rather than `disabled`, so the control
                        stays focusable and its tooltip says what unlocks it. --%>
                    <.action_button
                      variant={:secondary}
                      icon="hero-lock-closed"
                      class="flex-1 opacity-60"
                      aria-disabled="true"
                      title={dgettext("dashboard_appearance", "Connect Calendar to Preview")}
                    >
                      {dgettext("dashboard_appearance", "Live Preview")}
                    </.action_button>
                  <% end %>
                  <.action_button
                    icon="hero-adjustments-vertical"
                    class="flex-1"
                    phx-click="show_customization"
                    phx-value-theme={theme_id}
                    phx-target={@myself}
                  >
                    {dgettext("dashboard_appearance", "Customize Style")}
                  </.action_button>
                </div>
              </div>
            <% end %>
          </div>

          <.live_component
            module={BookingTextForm}
            id={"booking-text-form" <> page_suffix(@selected_page)}
            profile={@page_profile}
          />
        <% end %>
      </.dashboard_page>
    </div>
    """
  end

  @impl Phoenix.LiveComponent
  def handle_event("show_customization", %{"theme" => theme_id}, socket) do
    {:noreply, push_patch(socket, to: customize_path(theme_id, socket.assigns.selected_page))}
  end

  def handle_event("close_customization", _params, socket) do
    {:noreply, push_patch(socket, to: theme_path(socket.assigns.selected_page))}
  end

  def handle_event("select_theme", %{"theme" => theme_id}, socket) do
    if ThemeInfo.valid_theme_id?(theme_id) do
      {:noreply, apply_theme(socket, socket.assigns.selected_page, theme_id)}
    else
      {:noreply,
       Flash.put_flash(
         socket,
         :error,
         dgettext("dashboard_appearance", "Invalid theme selection")
       )}
    end
  end

  @doc """
  The Theme screen for `page`, or for the profile's own page when nil.
  """
  @spec theme_path(map() | nil) :: String.t()
  def theme_path(nil), do: ~p"/dashboard/theme"
  def theme_path(%{id: id}), do: ~p"/dashboard/theme?#{[page: id]}"

  defp customize_path(theme_id, nil), do: ~p"/dashboard/theme/customize/#{theme_id}"

  defp customize_path(theme_id, %{id: id}),
    do: ~p"/dashboard/theme/customize/#{theme_id}?#{[page: id]}"

  defp page_profile(profile, nil), do: profile
  defp page_profile(profile, page), do: BookingPages.apply_to_profile(profile, page)

  # The profile's own tab keeps the ids it always had; a page's tab gets its
  # own, so switching tabs mounts fresh editors instead of carrying state over.
  defp page_suffix(nil), do: ""
  defp page_suffix(%{id: id}), do: "-#{id}"

  defp apply_theme(socket, nil, theme_id) do
    case Profiles.update_booking_theme(socket.assigns.profile, theme_id) do
      {:ok, updated_profile} ->
        send(self(), {:profile_updated, updated_profile})

        socket
        |> assign(profile: updated_profile, page_profile: updated_profile)
        |> theme_updated(updated_profile.booking_theme)

      {:error, _changeset} ->
        theme_failed(socket)
    end
  end

  # A page's theme is the page's own. The dashboard is not told: it holds the
  # profile, and handing it the page's look would make that the profile's.
  defp apply_theme(socket, page, theme_id) do
    case BookingPages.update_theme(page, theme_id) do
      {:ok, page} ->
        socket
        |> assign(
          selected_page: page,
          page_profile: BookingPages.apply_to_profile(socket.assigns.profile, page)
        )
        |> theme_updated(page.booking_theme)

      {:error, _changeset} ->
        theme_failed(socket)
    end
  end

  defp theme_updated(socket, theme_id) do
    Flash.put_flash(
      socket,
      :info,
      dgettext("dashboard_appearance", "Theme updated to %{theme_name}",
        theme_name: ThemeInfo.get_theme_name(theme_id)
      )
    )
  end

  defp theme_failed(socket) do
    Flash.put_flash(socket, :error, dgettext("dashboard_appearance", "Failed to update theme"))
  end
end
```

- [ ] **Step 4: Save a page's booking texts to the page**

In `lib/tymeslot_web/live/dashboard/theme_settings/booking_text_form.ex`, add aliases:

```elixir
  alias Tymeslot.BookingPages
  alias Tymeslot.BookingPages.BookingPageSchema
```

In `save/2`, replace

```elixir
    case Profiles.update_booking_text(socket.assigns.profile, params) do
      {:ok, profile} ->
        send(self(), {:profile_updated, profile})
```

with

```elixir
    case persist_booking_text(socket.assigns.profile, params) do
      {:ok, profile} ->
        notify_profile_updated(profile)
```

and add after `save/2`:

```elixir
  # On a booking page's tab this form holds the owner's profile as the page
  # presents it, and the texts are the page's: they are written to the page,
  # and the dashboard's own profile is neither written nor told.
  defp persist_booking_text(%{booking_page: %BookingPageSchema{} = page} = profile, params) do
    case BookingPages.update_booking_text(page, params) do
      {:ok, page} ->
        {:ok, BookingPages.apply_to_profile(profile, page)}

      # The same rules, so the same errors, in the shape this form renders.
      {:error, _page_changeset} ->
        {:error, ProfileSchema.booking_text_changeset(profile, params)}
    end
  end

  defp persist_booking_text(profile, params), do: Profiles.update_booking_text(profile, params)

  defp notify_profile_updated(%{booking_page: %BookingPageSchema{}}), do: :ok
  defp notify_profile_updated(profile), do: send(self(), {:profile_updated, profile})
```

Replace `preview_url/2` (both clauses) with:

```elixir
  defp preview_url(%{user_id: user_id} = profile, token) when is_integer(user_id) do
    case BookingPages.public_address(profile) do
      address when is_binary(address) -> PreviewMode.owner_path(address, user_id) <> "&t=#{token}"
      _no_address -> nil
    end
  end

  defp preview_url(_profile, _token), do: nil
```

- [ ] **Step 5: Scope the colour editor and uploads by the profile they hold**

In `lib/tymeslot_web/live/dashboard/theme_settings/theme_customization_component.ex`:
- In `update/2`, change `ThemeCustomizations.initialize_customization(assigns.profile.id, theme_id)` to `ThemeCustomizations.initialize_customization(ThemeCustomizations.scope_for(assigns.profile), theme_id)`.
- In each of the five `ThemeCustomizations.apply_color_scheme_change(…)`, `apply_custom_palette_change(…)` and `apply_background_change(…)` calls, change the first argument `socket.assigns.profile.id` to `ThemeCustomizations.scope_for(socket.assigns.profile)`. Leave the two `socket.assigns.profile.id` uses in `with_rate_limit/3` and `emit_telemetry/3`; they identify the account in logs.
- In the moduledoc's assigns contract, after the `profile` line, add: `may be the owner's profile as one of its booking pages presents it; colours are then read and written for that page (ThemeCustomizations.scope_for/1)`.

In `lib/tymeslot_web/live/dashboard/theme_settings/background_uploads.ex`, in `apply_result({:ok, message}, socket)`, change `socket.assigns.profile.id,` to `ThemeCustomizations.scope_for(socket.assigns.profile),`.

In `lib/tymeslot_web/helpers/theme_upload_helper.ex`, in `process_background_image_upload/2` and `do_process_background_video_upload/2`, add as the first line of each body:

```elixir
    scope = ThemeCustomizations.scope_for(profile)
```

and change every `profile.id` in those two functions (two in the image function, three in the video function) to `scope`.

In `lib/tymeslot_web/live/dashboard/theme_settings/theme_customization/components.ex`, add `alias Tymeslot.BookingPages` and in the toolbar change

```elixir
            href={PreviewMode.owner_path(@profile.username, @profile.user_id, theme: @theme_id)}
```

to

```elixir
            href={
              PreviewMode.owner_path(BookingPages.public_address(@profile), @profile.user_id,
                theme: @theme_id
              )
            }
```

- [ ] **Step 6: Run the tests**

Run (mix): `test test/tymeslot_web/live/dashboard/booking_pages_theme_test.exs test/tymeslot_web/live/dashboard/theme_settings test/tymeslot_web/live/dashboard_routes_test.exs`
Expected: all pass, the existing theme settings tests included (their ids are unchanged on the profile's tab).

- [ ] **Step 7: Commit**

```bash
git add lib/tymeslot_web/live/dashboard/theme_settings_component.ex lib/tymeslot_web/live/dashboard/theme_settings/ \
  lib/tymeslot_web/helpers/theme_upload_helper.ex test/tymeslot_web/live/dashboard/booking_pages_theme_test.exs
git commit -m "feat(booking-pages): edit a booking page's theme, colours and texts"
```

---

### Task 10: Creating, renaming, filling and deleting pages

**Files:**
- Create: `lib/tymeslot_web/live/dashboard/theme_settings/pages_component.ex`
- Create: `lib/tymeslot_web/live/dashboard/theme_settings/page_settings_component.ex`
- Modify: `lib/tymeslot_web/live/dashboard/theme_settings_component.ex` (aliases; two insertions in `render/1`)
- Test: `test/tymeslot_web/live/dashboard/booking_pages_manage_test.exs`

**Interfaces:**
- Consumes: `BookingPages.max_pages/0`, `change_new/2`, `create/2`, `change_details/2`, `update_details/2`, `delete/1`, `set_meeting_type/3`, `memberships/1` (Tasks 3, 5); `BookingPageSchema.name_max_length/0` (Task 1); `ThemeSettingsComponent.theme_path/1` (Task 9); `MeetingTypes.get_all_meeting_types/1`, `get_meeting_type/2`, `set_private/2` (existing).
- Produces: `TymeslotWeb.Dashboard.ThemeSettings.PagesComponent` (assigns `profile`, `pages`, `selected_page`) and `TymeslotWeb.Dashboard.ThemeSettings.PageSettingsComponent` (assigns `profile`, `page`). DOM: tabs `#booking-page-tabs-tab-profile` / `#booking-page-tabs-tab-<id>`, `[data-testid='new-booking-page']`, form `#new-booking-page-form` (params under `page`), rows `#page-settings[-<id>]-type-<type id>`, form `#page-settings-<id>-details` (params under `page`), modal `#page-settings-<id>-delete`.

- [ ] **Step 1: Write the failing test**

```elixir
# test/tymeslot_web/live/dashboard/booking_pages_manage_test.exs
defmodule TymeslotWeb.Dashboard.BookingPagesManageTest do
  use TymeslotWeb.LiveCase, async: true

  @moduletag :dashboard
  @moduletag :themes

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.BookingPages
  alias Tymeslot.Repo

  setup :setup_dashboard_user_with_theme

  setup %{profile: profile} do
    %{profile: profile |> Ecto.Changeset.change(username: "joern") |> Repo.update!()}
  end

  test "creates a page from the dialog and opens its tab", %{conn: conn, profile: profile} do
    {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

    view |> element("[data-testid='new-booking-page']") |> render_click()

    view
    |> form("#new-booking-page-form", page: %{name: "einfachISO", slug: "einfachiso"})
    |> render_submit()

    [page] = BookingPages.list(profile.id)
    assert page.slug == "einfachiso"
    assert_patch(view, ~p"/dashboard/theme?#{[page: page.id]}")
  end

  test "the dialog refuses an address that is taken", %{conn: conn, profile: profile} do
    {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

    view |> element("[data-testid='new-booking-page']") |> render_click()

    html =
      view
      |> form("#new-booking-page-form", page: %{name: "Me again", slug: "joern"})
      |> render_submit()

    assert html =~ "has already been taken"
    assert BookingPages.list(profile.id) == []
  end

  test "the new page button stops at the cap", %{conn: conn, profile: profile} do
    for n <- 1..BookingPages.max_pages(),
        do: insert(:booking_page, profile: profile, slug: "cap-#{n}")

    {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

    assert has_element?(view, "[data-testid='new-booking-page'][disabled]")
  end

  test "a tab switches to its page", %{conn: conn, profile: profile} do
    page = insert(:booking_page, profile: profile, slug: "einfachiso")
    {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

    view |> element("#booking-page-tabs-tab-#{page.id}") |> render_click()

    assert_patch(view, ~p"/dashboard/theme?#{[page: page.id]}")
  end

  test "ticking a meeting type lists it on the page, and unticking removes it", ctx do
    page = insert(:booking_page, profile: ctx.profile, slug: "einfachiso")
    type = insert(:meeting_type, user: ctx.user, name: "ISO audit")
    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/theme?#{[page: page.id]}")

    view |> element("#page-settings-#{page.id}-type-#{type.id}") |> render_click()
    assert BookingPages.memberships(ctx.profile.id)[type.id] == MapSet.new([page.id])

    view |> element("#page-settings-#{page.id}-type-#{type.id}") |> render_click()
    refute Map.has_key?(BookingPages.memberships(ctx.profile.id), type.id)
  end

  test "on the username's tab the checklist works the unlisted flag", ctx do
    type = insert(:meeting_type, user: ctx.user, name: "Automation call", is_private: false)
    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/theme")

    view |> element("#page-settings-type-#{type.id}") |> render_click()

    assert Repo.reload!(type).is_private
  end

  test "renames a page and moves its address", %{conn: conn, profile: profile} do
    page = insert(:booking_page, profile: profile, slug: "einfachiso", name: "Old")
    {:ok, view, _html} = live(conn, ~p"/dashboard/theme?#{[page: page.id]}")

    view
    |> form("#page-settings-#{page.id}-details", page: %{name: "einfachISO", slug: "iso"})
    |> render_submit()

    assert %{name: "einfachISO", slug: "iso"} = Repo.reload!(page)
  end

  test "deletes a page after confirming", %{conn: conn, profile: profile} do
    page = insert(:booking_page, profile: profile, slug: "einfachiso")
    {:ok, view, _html} = live(conn, ~p"/dashboard/theme?#{[page: page.id]}")

    view |> element("[phx-click='show_delete']") |> render_click()
    view |> element("#page-settings-#{page.id}-delete button", "Delete page") |> render_click()

    assert BookingPages.list(profile.id) == []
    assert_patch(view, ~p"/dashboard/theme")
  end
end
```

- [ ] **Step 2: Run it to see it fail**

Run (mix): `test test/tymeslot_web/live/dashboard/booking_pages_manage_test.exs`
Expected: FAIL — no `[data-testid='new-booking-page']` element.

- [ ] **Step 3: Write the tabs component**

```elixir
# lib/tymeslot_web/live/dashboard/theme_settings/pages_component.ex
defmodule TymeslotWeb.Dashboard.ThemeSettings.PagesComponent do
  @moduledoc """
  The Theme screen's page tabs: the profile's own page at `/<username>` first,
  then each booking page, then the button that opens the new-page dialog.

  The selection lives in the URL (`?page=<id>`), so a tab is a patch and every
  editor on the screen follows it.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias Tymeslot.BookingPages
  alias Tymeslot.BookingPages.BookingPageSchema
  alias TymeslotWeb.Components.CoreComponents.Modal
  alias TymeslotWeb.Dashboard.ThemeSettingsComponent
  alias TymeslotWeb.Live.Shared.Flash

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:can_create, length(assigns.pages) < BookingPages.max_pages())
     |> assign_new(:show_new_page, fn -> false end)
     |> assign_new(:form, fn -> new_form(assigns.profile, %{}, nil) end)}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div class="mb-10 space-y-3">
      <.tab_bar
        id="booking-page-tabs"
        overflow={:wrap}
        aria_label={dgettext("dashboard_appearance", "Booking pages")}
        active_tab={active_tab(@selected_page)}
        target={@myself}
        event="switch_page"
        tabs={tabs(@profile, @pages)}
      >
        <:trailing>
          <%!-- Greyed out at the cap rather than removed, as the schedule
          switcher's button is: a ceiling should read as a ceiling. --%>
          <button
            type="button"
            disabled={not @can_create}
            phx-click={@can_create && "show_new_page"}
            phx-target={@myself}
            title={if(not @can_create, do: limit_message())}
            data-testid="new-booking-page"
            class={[
              "flex items-center gap-2 px-4 py-3 rounded-token-xl font-bold text-token-sm border-2 border-dashed transition-all duration-300",
              if(@can_create,
                do: "text-tymeslot-600 border-tymeslot-300 hover:border-tymeslot-400 hover:bg-white",
                else: "text-tymeslot-400 border-tymeslot-200 cursor-not-allowed"
              )
            ]}
          >
            <.icon name="hero-plus" class="w-4 h-4" />
            <span>{dgettext("dashboard_appearance", "New page")}</span>
          </button>
        </:trailing>
      </.tab_bar>

      <p :if={not @can_create} class="text-token-sm text-tymeslot-400 font-medium">
        {limit_message()}
      </p>

      <Modal.modal
        id="new-booking-page-modal"
        show={@show_new_page}
        on_cancel={JS.push("hide_new_page", target: @myself)}
      >
        <:header>{dgettext("dashboard_appearance", "New booking page")}</:header>

        <.form
          for={@form}
          id="new-booking-page-form"
          phx-change="validate_new_page"
          phx-submit="create_page"
          phx-target={@myself}
          class="space-y-6"
        >
          <.input
            field={@form[:name]}
            label={dgettext("dashboard_appearance", "Page name")}
            maxlength={BookingPageSchema.name_max_length()}
          />
          <.input field={@form[:slug]} label={dgettext("dashboard_appearance", "Address")} />
          <p class="text-token-sm text-tymeslot-500">
            {dgettext(
              "dashboard_appearance",
              "The page starts with your main page's theme and colours, its own texts switched off, and no meeting types."
            )}
          </p>
          <div class="flex justify-end gap-3">
            <.action_button
              type="button"
              variant={:secondary}
              phx-click="hide_new_page"
              phx-target={@myself}
            >
              {dgettext("dashboard_appearance", "Cancel")}
            </.action_button>
            <.action_button type="submit">
              {dgettext("dashboard_appearance", "Create page")}
            </.action_button>
          </div>
        </.form>
      </Modal.modal>
    </div>
    """
  end

  @impl Phoenix.LiveComponent
  def handle_event("switch_page", %{"tab" => "profile"}, socket),
    do: {:noreply, push_patch(socket, to: ThemeSettingsComponent.theme_path(nil))}

  def handle_event("switch_page", %{"tab" => id}, socket),
    do: {:noreply, push_patch(socket, to: ThemeSettingsComponent.theme_path(%{id: id}))}

  def handle_event("show_new_page", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_new_page, true)
     |> assign(:form, new_form(socket.assigns.profile, %{}, nil))}
  end

  def handle_event("hide_new_page", _params, socket),
    do: {:noreply, assign(socket, :show_new_page, false)}

  def handle_event("validate_new_page", %{"page" => params}, socket) do
    form = new_form(socket.assigns.profile, suggest_slug(params), :validate)
    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("create_page", %{"page" => params}, socket) do
    case BookingPages.create(socket.assigns.profile, params) do
      {:ok, page} ->
        Flash.info(dgettext("dashboard_appearance", "Booking page created"))

        {:noreply,
         socket
         |> assign(:show_new_page, false)
         |> push_patch(to: ThemeSettingsComponent.theme_path(page))}

      {:error, :limit_reached} ->
        Flash.error(limit_message())
        {:noreply, assign(socket, :show_new_page, false)}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :page))}
    end
  end

  defp new_form(profile, params, action) do
    profile
    |> BookingPages.change_new(params)
    |> Map.put(:action, action)
    |> to_form(as: :page)
  end

  # The address is suggested from the name until the host types one.
  defp suggest_slug(%{"slug" => slug} = params) when is_binary(slug) and slug != "", do: params

  defp suggest_slug(params) do
    slug =
      (params["name"] || "")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    Map.put(params, "slug", slug)
  end

  defp tabs(profile, pages) do
    [
      %{id: "profile", label: "/" <> (profile.username || "")}
      | Enum.map(pages, &%{id: to_string(&1.id), label: "/" <> &1.slug})
    ]
  end

  defp active_tab(nil), do: "profile"
  defp active_tab(page), do: to_string(page.id)

  defp limit_message do
    dgettext(
      "dashboard_appearance",
      "You have reached the limit of %{count} booking pages. Delete one to add another.",
      count: BookingPages.max_pages()
    )
  end
end
```

- [ ] **Step 4: Write the page settings component**

```elixir
# lib/tymeslot_web/live/dashboard/theme_settings/page_settings_component.ex
defmodule TymeslotWeb.Dashboard.ThemeSettings.PageSettingsComponent do
  @moduledoc """
  The selected page's own settings on the Theme screen: its address (to copy or
  open), the name and address of a booking page, the meeting types it lists,
  and deleting a booking page.

  `page` is nil for the profile's own page at `/<username>`, whose checklist
  works the meeting types' existing "unlisted" flag; on a booking page it works
  the page's listings (`BookingPages.set_meeting_type/3`).
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias Tymeslot.BookingPages
  alias Tymeslot.BookingPages.BookingPageSchema
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Utils.UrlBuilder
  alias TymeslotWeb.Components.CoreComponents.Modal
  alias TymeslotWeb.Dashboard.ThemeSettingsComponent
  alias TymeslotWeb.Live.Shared.Flash

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:show_delete, fn -> false end)
     |> assign_new(:details_form, fn -> details_form(assigns.page) end)
     |> load_listings()}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id={@id} class="mt-16">
      <.section_header icon="hero-globe-alt" title={dgettext("dashboard_appearance", "This page")} />

      <.card padding={:lg} class="space-y-8">
        <div class="space-y-2">
          <p class="label">{dgettext("dashboard_appearance", "Address")}</p>
          <div class="flex flex-wrap items-center gap-3">
            <code class="text-token-sm font-semibold text-tymeslot-700 break-all">
              {page_url(@profile, @page)}
            </code>
            <.action_button
              id={"#{@id}-copy"}
              type="button"
              variant={:secondary}
              icon="hero-clipboard-document"
              phx-hook="CopyOnClick"
              data-copy-text={page_url(@profile, @page)}
            >
              {dgettext("dashboard_appearance", "Copy link")}
            </.action_button>
            <.action_link
              href={page_url(@profile, @page)}
              target="_blank"
              rel="noopener noreferrer"
              variant={:secondary}
              icon="hero-arrow-top-right-on-square"
            >
              {dgettext("dashboard_appearance", "Open")}
            </.action_link>
          </div>
        </div>

        <.form
          :if={@page}
          for={@details_form}
          id={"#{@id}-details"}
          phx-change="validate_details"
          phx-submit="save_details"
          phx-target={@myself}
          class="space-y-4"
        >
          <.input
            field={@details_form[:name]}
            label={dgettext("dashboard_appearance", "Page name")}
            maxlength={BookingPageSchema.name_max_length()}
          />
          <.input field={@details_form[:slug]} label={dgettext("dashboard_appearance", "Address")} />
          <p class="text-token-sm text-tymeslot-500">
            {dgettext(
              "dashboard_appearance",
              "Changing the address stops the old one working at once. Links in emails you have already sent keep working."
            )}
          </p>
          <.action_button type="submit">{dgettext("dashboard_appearance", "Save")}</.action_button>
        </.form>

        <div class="space-y-3">
          <p class="label">{dgettext("dashboard_appearance", "Meeting types on this page")}</p>
          <p :if={@meeting_types == []} class="text-token-sm text-tymeslot-500">
            {dgettext("dashboard_appearance", "No meeting types yet.")}
          </p>
          <.setting_row
            :for={type <- @meeting_types}
            id={"#{@id}-type-#{type.id}"}
            label={type.name}
            description={inactive_note(type)}
            checked={listed?(@page, @memberships, type)}
            on_change="toggle_type"
            target={@myself}
            phx-value-id={type.id}
          />
        </div>

        <div :if={@page} class="pt-4 border-t border-tymeslot-100">
          <.action_button
            type="button"
            variant={:danger}
            icon="hero-trash"
            phx-click="show_delete"
            phx-target={@myself}
          >
            {dgettext("dashboard_appearance", "Delete page")}
          </.action_button>
        </div>
      </.card>

      <Modal.confirm_modal
        :if={@page}
        id={"#{@id}-delete"}
        show={@show_delete}
        title={dgettext("dashboard_appearance", "Delete booking page")}
        confirm_label={dgettext("dashboard_appearance", "Delete page")}
        on_cancel={JS.push("hide_delete", target: @myself)}
        on_confirm={JS.push("confirm_delete", target: @myself)}
      >
        <p>
          {dgettext(
            "dashboard_appearance",
            "Delete %{address}? Bookings made through it keep working and show your main page's look. Its colours and uploaded backgrounds are removed.",
            address: "/" <> @page.slug
          )}
        </p>
      </Modal.confirm_modal>
    </div>
    """
  end

  @impl Phoenix.LiveComponent
  def handle_event("toggle_type", %{"id" => id}, socket) do
    user_id = socket.assigns.profile.user_id

    with {type_id, ""} <- Integer.parse(id),
         %{} = type <- MeetingTypes.get_meeting_type(type_id, user_id),
         :ok <- toggle(socket.assigns.page, socket.assigns.memberships, type) do
      send(self(), {:meeting_type_changed})
      Flash.info(dgettext("dashboard_appearance", "Booking page saved"))
      {:noreply, load_listings(socket)}
    else
      _not_found_or_failed -> {:noreply, socket}
    end
  end

  def handle_event("validate_details", %{"page" => params}, socket) do
    changeset = BookingPages.change_details(socket.assigns.page, params)
    {:noreply, assign(socket, :details_form, to_form(changeset, as: :page))}
  end

  def handle_event("save_details", %{"page" => params}, socket) do
    case BookingPages.update_details(socket.assigns.page, params) do
      {:ok, page} ->
        Flash.info(dgettext("dashboard_appearance", "Booking page saved"))
        {:noreply, push_patch(socket, to: ThemeSettingsComponent.theme_path(page))}

      {:error, changeset} ->
        {:noreply, assign(socket, :details_form, to_form(changeset, as: :page))}
    end
  end

  def handle_event("show_delete", _params, socket),
    do: {:noreply, assign(socket, :show_delete, true)}

  def handle_event("hide_delete", _params, socket),
    do: {:noreply, assign(socket, :show_delete, false)}

  def handle_event("confirm_delete", _params, socket) do
    case BookingPages.delete(socket.assigns.page) do
      {:ok, _page} ->
        Flash.info(dgettext("dashboard_appearance", "Booking page deleted"))

        {:noreply,
         socket
         |> assign(:show_delete, false)
         |> push_patch(to: ThemeSettingsComponent.theme_path(nil))}

      {:error, _reason} ->
        Flash.error(
          dgettext("dashboard_appearance", "Could not delete the booking page. Please try again.")
        )

        {:noreply, assign(socket, :show_delete, false)}
    end
  end

  defp load_listings(socket) do
    profile = socket.assigns.profile

    socket
    |> assign(:meeting_types, MeetingTypes.get_all_meeting_types(profile.user_id))
    |> assign(:memberships, BookingPages.memberships(profile.id))
  end

  defp details_form(nil), do: nil

  defp details_form(page),
    do: page |> BookingPages.change_details(%{}) |> Map.put(:action, nil) |> to_form(as: :page)

  # The profile's own page is the type's existing "unlisted" flag.
  defp toggle(nil, _memberships, type) do
    case MeetingTypes.set_private(type, !type.is_private) do
      {:ok, _type} -> :ok
      {:error, _reason} -> :error
    end
  end

  defp toggle(page, memberships, type),
    do: BookingPages.set_meeting_type(page, type.id, not listed?(page, memberships, type))

  defp listed?(nil, _memberships, type), do: not type.is_private

  defp listed?(page, memberships, type),
    do: MapSet.member?(Map.get(memberships, type.id, MapSet.new()), page.id)

  defp inactive_note(%{is_active: true}), do: nil

  defp inactive_note(_type),
    do: dgettext("dashboard_appearance", "Inactive: not offered anywhere until you turn it back on.")

  defp page_url(profile, nil), do: UrlBuilder.booking_url(profile.username)
  defp page_url(_profile, page), do: UrlBuilder.booking_url(page.slug)
end
```

- [ ] **Step 5: Mount both on the Theme screen**

In `lib/tymeslot_web/live/dashboard/theme_settings_component.ex`, add aliases:

```elixir
  alias TymeslotWeb.Dashboard.ThemeSettings.PageSettingsComponent
  alias TymeslotWeb.Dashboard.ThemeSettings.PagesComponent
```

In `render/1`, as the first child of the `<% else %>` branch (directly above `<div class="mb-16 max-w-2xl">`), insert:

```elixir
          <.live_component
            module={PagesComponent}
            id="booking-pages"
            profile={@profile}
            pages={@pages}
            selected_page={@selected_page}
          />
```

and directly below the `BookingTextForm` live component, insert:

```elixir
          <.live_component
            module={PageSettingsComponent}
            id={"page-settings" <> page_suffix(@selected_page)}
            profile={@profile}
            page={@selected_page}
          />
```

- [ ] **Step 6: Run the tests**

Run (mix): `test test/tymeslot_web/live/dashboard/booking_pages_manage_test.exs test/tymeslot_web/live/dashboard/booking_pages_theme_test.exs test/tymeslot_web/live/dashboard/theme_settings`
Expected: all pass. If the confirm button cannot be found by its text, read `render(view)` and select it by the attribute `Modal.confirm_modal/1` gives it (for example `#page-settings-<id>-delete [phx-click*='confirm_delete']`).

- [ ] **Step 7: Commit**

```bash
git add lib/tymeslot_web/live/dashboard/theme_settings_component.ex lib/tymeslot_web/live/dashboard/theme_settings/pages_component.ex \
  lib/tymeslot_web/live/dashboard/theme_settings/page_settings_component.ex test/tymeslot_web/live/dashboard/booking_pages_manage_test.exs
git commit -m "feat(booking-pages): create, rename, fill and delete booking pages"
```

---

### Task 11: Meeting types show where they are listed

**Files:**
- Create: `lib/tymeslot_web/live/dashboard/meeting_settings/page_visibility.ex`
- Modify: `lib/tymeslot_web/live/dashboard/meeting_settings/meeting_type_form/visibility_section.ex`
- Modify: `lib/tymeslot_web/live/dashboard/meeting_settings/meeting_type_form/form_view.ex` (~line 359)
- Modify: `lib/tymeslot_web/live/dashboard/meeting_settings/meeting_type_form.ex` (`mount/1`)
- Modify: `lib/tymeslot_web/live/dashboard/service_settings_component.ex`
- Modify: `lib/tymeslot_web/live/dashboard/service_settings/component_view.ex`
- Modify: `lib/tymeslot_web/live/dashboard/meeting_settings/meeting_types_list_component.ex`
- Modify: `lib/tymeslot_web/live/dashboard/meeting_settings/card.ex`
- Modify: `test/tymeslot_web/live/dashboard/meeting_settings_test.exs` (~lines 175–191)
- Test: `test/tymeslot_web/live/dashboard/meeting_settings/booking_page_visibility_test.exs`

**Interfaces:**
- Consumes: `BookingPages.list/1`, `fetch/2`, `memberships/1`, `set_meeting_type/3`.
- Produces: `PageVisibility.rows(username :: String.t() | nil, pages, memberships, type | nil) :: [%{id: String.t(), address: String.t(), checked: boolean()}]`, the `"profile"` row first.
- Produces: `PageVisibility.unlisted?(memberships, type) :: boolean()`; `PageVisibility.addresses(username, pages, memberships, type) :: [String.t()]` (empty while there are no booking pages).
- Produces: event `toggle_page_membership` (`phx-value-id` = meeting type id, `phx-value-page` = page id) on `ServiceSettingsComponent`.

- [ ] **Step 1: Write the failing test**

```elixir
# test/tymeslot_web/live/dashboard/meeting_settings/booking_page_visibility_test.exs
defmodule TymeslotWeb.Dashboard.MeetingSettings.BookingPageVisibilityTest do
  use TymeslotWeb.LiveCase, async: true

  @moduletag :meeting_types
  @moduletag :dashboard

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.BookingPages
  alias Tymeslot.Repo
  alias TymeslotWeb.Dashboard.MeetingSettings.PageVisibility

  setup :setup_dashboard_user_with_theme

  setup %{profile: profile} do
    profile = profile |> Ecto.Changeset.change(username: "joern") |> Repo.update!()
    page = insert(:booking_page, profile: profile, slug: "einfachiso")
    %{profile: profile, page: page}
  end

  describe "PageVisibility" do
    test "rows put the username first and tick what lists the type", %{page: page} do
      type = %{id: 1, is_private: true}

      assert PageVisibility.rows("joern", [page], %{1 => MapSet.new([page.id])}, type) == [
               %{id: "profile", address: "joern", checked: false},
               %{id: to_string(page.id), address: "einfachiso", checked: true}
             ]

      assert PageVisibility.rows("joern", [page], %{}, nil) == []
    end

    test "a type is unlisted only when it is on no page", %{page: page} do
      refute PageVisibility.unlisted?(%{1 => MapSet.new([page.id])}, %{id: 1, is_private: true})
      assert PageVisibility.unlisted?(%{}, %{id: 1, is_private: true})
      refute PageVisibility.unlisted?(%{}, %{id: 1, is_private: false})
    end

    test "addresses stay empty until there are booking pages" do
      assert PageVisibility.addresses("joern", [], %{}, %{id: 1, is_private: false}) == []
    end
  end

  test "the editor lists a type on a page and the card names it", ctx do
    type = insert(:meeting_type, user: ctx.user, name: "ISO audit", is_private: true)
    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard/meeting-settings")

    view |> element("[phx-click='edit_type'][phx-value-id='#{type.id}']") |> render_click()
    assert has_element?(view, "[data-testid='unlisted-note']")

    view
    |> element("[phx-click='toggle_page_membership'][phx-value-page='#{ctx.page.id}']")
    |> render_click()

    assert BookingPages.memberships(ctx.profile.id)[type.id] == MapSet.new([ctx.page.id])
    refute has_element?(view, "[data-testid='unlisted-note']")

    view |> element("button", "Done") |> render_click()
    html = render(view)
    assert html =~ "/einfachiso"
    refute html =~ "Unlisted"
  end
end
```

- [ ] **Step 2: Run it to see it fail**

Run (mix): `test test/tymeslot_web/live/dashboard/meeting_settings/booking_page_visibility_test.exs`
Expected: FAIL — `PageVisibility` is undefined.

- [ ] **Step 3: Write `PageVisibility`**

```elixir
# lib/tymeslot_web/live/dashboard/meeting_settings/page_visibility.ex
defmodule TymeslotWeb.Dashboard.MeetingSettings.PageVisibility do
  @moduledoc """
  Where a meeting type is listed, shaped for the meeting type editor's
  Visibility switches and the meeting type cards.

  The profile's own page at `/<username>` is the type's `is_private` flag;
  each booking page is a listing (`Tymeslot.BookingPages.memberships/1`). A type
  listed nowhere is unlisted: bookable only through its direct link.
  """

  @type row :: %{id: String.t(), address: String.t(), checked: boolean()}

  @doc "One row per page, the username's first; none without a type."
  @spec rows(String.t() | nil, [map()], map(), map() | nil) :: [row()]
  def rows(_username, _pages, _memberships, nil), do: []

  def rows(username, pages, memberships, type) do
    listed_on = Map.get(memberships, type.id, MapSet.new())

    [
      %{id: "profile", address: username || "", checked: not type.is_private}
      | Enum.map(pages, fn page ->
          %{id: to_string(page.id), address: page.slug, checked: MapSet.member?(listed_on, page.id)}
        end)
    ]
  end

  @doc "Whether a type is on no page at all."
  @spec unlisted?(map(), map()) :: boolean()
  def unlisted?(memberships, type),
    do: type.is_private and not Map.has_key?(memberships, type.id)

  @doc """
  The addresses a type is listed on, for its card. Empty while the profile has
  no booking pages, where the "Unlisted" badge says it all.
  """
  @spec addresses(String.t() | nil, [map()], map(), map()) :: [String.t()]
  def addresses(_username, [], _memberships, _type), do: []

  def addresses(username, pages, memberships, type) do
    username
    |> rows(pages, memberships, type)
    |> Enum.filter(& &1.checked)
    |> Enum.map(& &1.address)
  end
end
```

- [ ] **Step 4: One switch per page in the editor**

In `meeting_type_form/visibility_section.ex`, keep the module name and `use` lines, change the moduledoc's first paragraph to "Renders one "Show on …" switch per page for a meeting type: the profile's own page at `/<username>` dispatches `toggle_private`, a booking page `toggle_page_membership`, both to the parent `ServiceSettingsComponent` (`@parent`), which owns persistence.", and replace the attrs and `visibility_section/1` with:

```elixir
  attr :type, :map, default: nil
  attr :parent, :any, required: true
  attr :pages, :list, default: [], doc: "`PageVisibility.rows/4`, the username's page first"

  @spec visibility_section(map()) :: Phoenix.LiveView.Rendered.t()
  def visibility_section(assigns) do
    ~H"""
    <section :if={@pages != []} class="space-y-4">
      <.subsection_header
        icon="hero-eye-slash"
        title={dgettext("dashboard_meeting_form", "Visibility")}
      />

      <.setting_row
        :for={page <- @pages}
        id={toggle_id(@type, page)}
        control={:switch}
        label={dgettext("dashboard_meeting_form", "Show on %{address}", address: "/" <> page.address)}
        checked={page.checked}
        on_change={toggle_event(page)}
        target={@parent}
        phx-value-id={@type.id}
        phx-value-page={page.id}
      />

      <p
        :if={Enum.all?(@pages, &(not &1.checked))}
        class="text-token-sm text-tymeslot-500"
        data-testid="unlisted-note"
      >
        {dgettext(
          "dashboard_meeting_form",
          "On no booking page: bookable only through its direct link."
        )}
      </p>
    </section>
    """
  end

  # The username's page keeps the control id and event it always had.
  defp toggle_id(type, %{id: "profile"}), do: "meeting-type-private-toggle-#{type.id}"
  defp toggle_id(type, page), do: "meeting-type-page-toggle-#{type.id}-#{page.id}"

  defp toggle_event(%{id: "profile"}), do: "toggle_private"
  defp toggle_event(_page), do: "toggle_page_membership"
```

In `form_view.ex`, add `alias TymeslotWeb.Dashboard.MeetingSettings.PageVisibility` and replace

```elixir
          <.visibility_section type={@type} parent={@parent_myself} />
```

with

```elixir
          <.visibility_section
            type={@type}
            parent={@parent_myself}
            pages={PageVisibility.rows(@username, @booking_pages, @page_memberships, @type)}
          />
```

In `meeting_type_form.ex` `mount/1`, add to the assign chain, and add `username`, `booking_pages`, `page_memberships` to the "Public assigns passed from parent" comment:

```elixir
     |> assign(:username, nil)
     |> assign(:booking_pages, [])
     |> assign(:page_memberships, %{})
```

- [ ] **Step 5: Load pages and handle the page switch in the parent**

In `service_settings_component.ex`, add `alias Tymeslot.BookingPages`. In `update/2`, after `|> assign(:payment_currency, host_currency(data.meeting_types, user_id))`, add:

```elixir
      |> assign(:booking_pages, BookingPages.list(socket.assigns.profile.id))
      |> assign(:page_memberships, BookingPages.memberships(socket.assigns.profile.id))
```

Add the event after `handle_event("toggle_private", …)`:

```elixir
  def handle_event("toggle_page_membership", %{"id" => id, "page" => page_id}, socket) do
    user_id = socket.assigns.current_user.id

    with_rate_limit(RateLimiter.check_meeting_type_write_rate_limit(user_id), socket, fn ->
      do_toggle_page_membership(socket, String.to_integer(id), page_id, user_id)
    end)
  end
```

and after `do_toggle_private/3`:

```elixir
  defp do_toggle_page_membership(socket, type_id, page_id, user_id) do
    profile_id = socket.assigns.profile.id

    with %{} = type <- MeetingTypes.get_meeting_type(type_id, user_id),
         {:ok, page} <- BookingPages.fetch(profile_id, page_id) do
      listed_on = Map.get(socket.assigns.page_memberships, type.id, MapSet.new())
      :ok = BookingPages.set_meeting_type(page, type.id, not MapSet.member?(listed_on, page.id))

      send(self(), {:meeting_type_changed})
      Flash.info(dgettext("dashboard_integrations", "Visibility updated"))
      {:noreply, assign(socket, :page_memberships, BookingPages.memberships(profile_id))}
    else
      _not_found ->
        Flash.error(dgettext("dashboard_integrations", "Failed to update visibility"))
        {:noreply, socket}
    end
  end
```

In `service_settings/component_view.ex`, pass to the `MeetingTypeForm` live component (after `group_bookings_allowed={@group_bookings_allowed}`):

```elixir
              username={@profile.username}
              booking_pages={@booking_pages}
              page_memberships={@page_memberships}
```

and to `MeetingTypesListComponent.meeting_types_section` (after `group_bookings_allowed={@group_bookings_allowed}`):

```elixir
                username={@profile.username}
                booking_pages={@booking_pages}
                page_memberships={@page_memberships}
```

- [ ] **Step 6: Badges and chips on the cards**

In `meeting_types_list_component.ex`, add `alias TymeslotWeb.Dashboard.MeetingSettings.PageVisibility`, add to `meeting_types_section`'s attrs:

```elixir
  attr :username, :string, default: nil
  attr :booking_pages, :list, default: []
  attr :page_memberships, :map, default: %{}
```

and pass to each `Card.meeting_type_card`:

```elixir
                unlisted={PageVisibility.unlisted?(@page_memberships, type)}
                page_addresses={
                  PageVisibility.addresses(@username, @booking_pages, @page_memberships, type)
                }
```

In `card.ex`, add to `meeting_type_card`'s attrs:

```elixir
  attr :unlisted, :boolean,
    default: nil,
    doc: "on no page at all; nil falls back to the type's own `is_private`"

  attr :page_addresses, :list, default: [], doc: "the addresses the type is listed on"
```

change the "Unlisted" pill's `:if={@type.is_private}` to `:if={if(is_nil(@unlisted), do: @type.is_private, else: @unlisted)}`, and add after the "Paused" pill:

```elixir
            <Feedback.pill :for={address <- @page_addresses} size={:sm} icon="hero-globe-alt-mini">
              {"/" <> address}
            </Feedback.pill>
```

- [ ] **Step 7: Bring the existing switch test in line**

In `test/tymeslot_web/live/dashboard/meeting_settings_test.exs`, test "the visibility toggle lives in the Booking Rules panel and persists": the switch now reads "Show on /<username>", so it starts on and ends off. Swap `[aria-checked='false']` in the first `has_element?` and `[aria-checked='true']` in the last, and replace the comment above the first assertion with:

```elixir
      # The switch reads "Show on /<username>": on while the type is listed.
      # A switch must state "false" when off: a boolean false drops the
      # attribute, leaving screen readers with no state at all.
```

- [ ] **Step 8: Run the tests**

Run (mix): `test test/tymeslot_web/live/dashboard/meeting_settings test/tymeslot_web/live/dashboard/meeting_settings_test.exs test/tymeslot/meeting_types`
Expected: all pass.

- [ ] **Step 9: Commit**

```bash
git add lib/tymeslot_web/live/dashboard/meeting_settings/ lib/tymeslot_web/live/dashboard/service_settings_component.ex \
  lib/tymeslot_web/live/dashboard/service_settings/component_view.ex test/tymeslot_web/live/dashboard/meeting_settings_test.exs \
  test/tymeslot_web/live/dashboard/meeting_settings/booking_page_visibility_test.exs
git commit -m "feat(booking-pages): show and set the pages a meeting type is listed on"
```

---

### Task 12: Embed a booking page

**Files:**
- Modify: `lib/tymeslot_web/live/dashboard/embed_settings_component.ex`
- Test: `test/tymeslot_web/live/dashboard/embed_booking_pages_test.exs`

**Interfaces:**
- Consumes: `BookingPages.list/1`, `apply_to_profile/2`, `public_address/1`.
- Produces: form `#embed-page-picker` (`phx-change="select_page"`, field `page` = `"profile"` or a page id); `@username`, `@theme_id`, `@booking_url` follow the choice.

- [ ] **Step 1: Write the failing test**

```elixir
# test/tymeslot_web/live/dashboard/embed_booking_pages_test.exs
defmodule TymeslotWeb.Dashboard.EmbedBookingPagesTest do
  use TymeslotWeb.LiveCase, async: true

  @moduletag :dashboard

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Repo

  setup :setup_dashboard_user_with_theme

  setup %{profile: profile} do
    %{profile: profile |> Ecto.Changeset.change(username: "joern") |> Repo.update!()}
  end

  test "without booking pages there is no picker", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboard/embed")

    refute has_element?(view, "#embed-page-picker")
  end

  test "the snippet follows the chosen page", %{conn: conn, profile: profile} do
    page = insert(:booking_page, profile: profile, slug: "einfachiso")
    {:ok, view, html} = live(conn, ~p"/dashboard/embed")

    assert html =~ ~r/data-username=(&quot;|")joern/

    html =
      view
      |> form("#embed-page-picker", %{"page" => to_string(page.id)})
      |> render_change()

    assert html =~ ~r/data-username=(&quot;|")einfachiso/
  end
end
```

- [ ] **Step 2: Run it to see it fail**

Run (mix): `test test/tymeslot_web/live/dashboard/embed_booking_pages_test.exs`
Expected: FAIL — no `#embed-page-picker`.

- [ ] **Step 3: Add the picker**

In `embed_settings_component.ex`, add `alias Tymeslot.BookingPages`. In `update/2`, delete the lines `username = profile.username` and `theme_id = profile.booking_theme || "1"`, and the three assigns `|> assign(:username, username)`, `|> assign(:theme_id, theme_id)` and `|> assign(:booking_url, UrlBuilder.booking_url(username))`. Append to the end of the assign chain, before `{:ok, socket}`:

```elixir
      |> assign(:pages, BookingPages.list(profile.id))
      |> assign_new(:selected_page_id, fn -> nil end)
      |> assign_page_target()
```

In `render/1`, as the first child of `<div class="space-y-6">` (above the `.tab_bar`), insert:

```elixir
          <.form
            :if={@pages != []}
            for={to_form(%{}, as: :embed_page)}
            id="embed-page-picker"
            phx-change="select_page"
            phx-target={@myself}
          >
            <.input
              type="select"
              name="page"
              label={dgettext("dashboard_embed", "Booking page")}
              value={if(@selected_page_id, do: to_string(@selected_page_id), else: "profile")}
              options={page_options(@profile, @pages)}
            />
          </.form>
```

Add the event and helpers:

```elixir
  def handle_event("select_page", %{"page" => "profile"}, socket),
    do: {:noreply, socket |> assign(:selected_page_id, nil) |> assign_page_target()}

  def handle_event("select_page", %{"page" => id}, socket) do
    page_id = Enum.find_value(socket.assigns.pages, &(to_string(&1.id) == id && &1.id))
    {:noreply, socket |> assign(:selected_page_id, page_id) |> assign_page_target()}
  end

  # The snippet, link and preview follow the chosen page: its address in place
  # of the username, and its theme. Allowed embed domains stay the profile's.
  defp assign_page_target(socket) do
    %{profile: profile, pages: pages, selected_page_id: page_id} = socket.assigns

    shown =
      case Enum.find(pages, &(&1.id == page_id)) do
        nil -> profile
        page -> BookingPages.apply_to_profile(profile, page)
      end

    address = BookingPages.public_address(shown)

    socket
    |> assign(:username, address)
    |> assign(:theme_id, shown.booking_theme || "1")
    |> assign(:booking_url, UrlBuilder.booking_url(address))
  end

  defp page_options(profile, pages) do
    [
      {"/" <> (profile.username || ""), "profile"}
      | Enum.map(pages, &{"/" <> &1.slug, to_string(&1.id)})
    ]
  end
```

- [ ] **Step 4: Run the tests**

Run (mix): `test test/tymeslot_web/live/dashboard/embed_booking_pages_test.exs`
Then run every existing embed test: list them with `git grep -l "dashboard/embed" -- test` and pass those paths to `test`.
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/tymeslot_web/live/dashboard/embed_settings_component.ex test/tymeslot_web/live/dashboard/embed_booking_pages_test.exs
git commit -m "feat(booking-pages): embed a chosen booking page"
```

---

### Task 13: Translations

**Files:**
- Modify: `priv/gettext/*.pot` and `priv/gettext/*/LC_MESSAGES/{dashboard_appearance,dashboard_meeting_form,dashboard_embed,errors}.po`

**Interfaces:**
- Consumes: every string added in Tasks 1 and 9–12.

- [ ] **Step 1: Extract**

Run (mix, `MIX_ENV=dev`): `gettext.extract --merge`
Expected: new msgids in `dashboard_appearance`, `dashboard_meeting_form`, `dashboard_embed` and `errors`; "Hide from public booking page" and its description disappear from `dashboard_meeting_form`.

- [ ] **Step 2: Clear fuzzy guesses**

List flagged entries with `git grep -n "fuzzy" -- priv/gettext`. For every hit in the four domains above, delete `, fuzzy` from its flags line and empty its `msgstr`: it is a guess copied from a similar string, and Step 3 fills it properly.

- [ ] **Step 3: Fill the translations**

Save the script below in a scratch directory outside the repo (for example `/tmp/fill_po.py`) and run it from the repo root with `python3 -I /tmp/fill_po.py`. It fills only the empty msgstrs of these msgids, and prints each one it fills.

```python
import re
from pathlib import Path

T = {
 "dashboard_appearance": {
  "You are editing %{address}": {"cs":"Upravujete %{address}","de":"Sie bearbeiten %{address}","fr":"Vous modifiez %{address}","it":"Stai modificando %{address}","pl":"Edytujesz %{address}","pt":"Você está editando %{address}","uk":"Ви редагуєте %{address}"},
  "Booking pages": {"cs":"Rezervační stránky","de":"Buchungsseiten","fr":"Pages de réservation","it":"Pagine di prenotazione","pl":"Strony rezerwacji","pt":"Páginas de agendamento","uk":"Сторінки бронювання"},
  "New page": {"cs":"Nová stránka","de":"Neue Seite","fr":"Nouvelle page","it":"Nuova pagina","pl":"Nowa strona","pt":"Nova página","uk":"Нова сторінка"},
  "You have reached the limit of %{count} booking pages. Delete one to add another.": {"cs":"Dosáhli jste limitu %{count} rezervačních stránek. Chcete-li přidat další, jednu smažte.","de":"Sie haben das Limit von %{count} Buchungsseiten erreicht. Löschen Sie eine, um eine weitere hinzuzufügen.","fr":"Vous avez atteint la limite de %{count} pages de réservation. Supprimez-en une pour en ajouter une autre.","it":"Hai raggiunto il limite di %{count} pagine di prenotazione. Eliminane una per aggiungerne un'altra.","pl":"Osiągnięto limit %{count} stron rezerwacji. Usuń jedną, aby dodać kolejną.","pt":"Você atingiu o limite de %{count} páginas de agendamento. Exclua uma para adicionar outra.","uk":"Ви досягли ліміту в %{count} сторінок бронювання. Видаліть одну, щоб додати іншу."},
  "New booking page": {"cs":"Nová rezervační stránka","de":"Neue Buchungsseite","fr":"Nouvelle page de réservation","it":"Nuova pagina di prenotazione","pl":"Nowa strona rezerwacji","pt":"Nova página de agendamento","uk":"Нова сторінка бронювання"},
  "Page name": {"cs":"Název stránky","de":"Name der Seite","fr":"Nom de la page","it":"Nome della pagina","pl":"Nazwa strony","pt":"Nome da página","uk":"Назва сторінки"},
  "Address": {"cs":"Adresa","de":"Adresse","fr":"Adresse","it":"Indirizzo","pl":"Adres","pt":"Endereço","uk":"Адреса"},
  "The page starts with your main page's theme and colours, its own texts switched off, and no meeting types.": {"cs":"Stránka začne s motivem a barvami vaší hlavní stránky, bez vlastních textů a bez typů schůzek.","de":"Die Seite übernimmt Design und Farben Ihrer Hauptseite, ohne eigene Texte und ohne Termintypen.","fr":"La page reprend le thème et les couleurs de votre page principale, sans textes propres ni types de réunion.","it":"La pagina parte con il tema e i colori della tua pagina principale, senza testi propri e senza tipi di riunione.","pl":"Strona startuje z motywem i kolorami strony głównej, bez własnych tekstów i bez typów spotkań.","pt":"A página começa com o tema e as cores da sua página principal, sem textos próprios e sem tipos de reunião.","uk":"Сторінка отримає тему й кольори вашої головної сторінки, без власних текстів і без типів зустрічей."},
  "Cancel": {"cs":"Zrušit","de":"Abbrechen","fr":"Annuler","it":"Annulla","pl":"Anuluj","pt":"Cancelar","uk":"Скасувати"},
  "Create page": {"cs":"Vytvořit stránku","de":"Seite erstellen","fr":"Créer la page","it":"Crea pagina","pl":"Utwórz stronę","pt":"Criar página","uk":"Створити сторінку"},
  "Booking page created": {"cs":"Rezervační stránka byla vytvořena","de":"Buchungsseite erstellt","fr":"Page de réservation créée","it":"Pagina di prenotazione creata","pl":"Utworzono stronę rezerwacji","pt":"Página de agendamento criada","uk":"Сторінку бронювання створено"},
  "This page": {"cs":"Tato stránka","de":"Diese Seite","fr":"Cette page","it":"Questa pagina","pl":"Ta strona","pt":"Esta página","uk":"Ця сторінка"},
  "Copy link": {"cs":"Kopírovat odkaz","de":"Link kopieren","fr":"Copier le lien","it":"Copia link","pl":"Kopiuj link","pt":"Copiar link","uk":"Копіювати посилання"},
  "Open": {"cs":"Otevřít","de":"Öffnen","fr":"Ouvrir","it":"Apri","pl":"Otwórz","pt":"Abrir","uk":"Відкрити"},
  "Changing the address stops the old one working at once. Links in emails you have already sent keep working.": {"cs":"Po změně adresy přestane stará ihned fungovat. Odkazy v již odeslaných e-mailech fungují dál.","de":"Wenn Sie die Adresse ändern, funktioniert die alte sofort nicht mehr. Links in bereits versendeten E-Mails funktionieren weiterhin.","fr":"Changer l'adresse désactive aussitôt l'ancienne. Les liens des e-mails déjà envoyés continuent de fonctionner.","it":"Se cambi l'indirizzo, quello vecchio smette subito di funzionare. I link nelle email già inviate continuano a funzionare.","pl":"Po zmianie adresu stary od razu przestaje działać. Linki w już wysłanych e-mailach działają dalej.","pt":"Ao mudar o endereço, o antigo deixa de funcionar na hora. Os links em e-mails já enviados continuam funcionando.","uk":"Після зміни адреси стара одразу перестане працювати. Посилання в уже надісланих листах працюватимуть і далі."},
  "Save": {"cs":"Uložit","de":"Speichern","fr":"Enregistrer","it":"Salva","pl":"Zapisz","pt":"Salvar","uk":"Зберегти"},
  "Meeting types on this page": {"cs":"Typy schůzek na této stránce","de":"Termintypen auf dieser Seite","fr":"Types de réunion sur cette page","it":"Tipi di riunione in questa pagina","pl":"Typy spotkań na tej stronie","pt":"Tipos de reunião nesta página","uk":"Типи зустрічей на цій сторінці"},
  "No meeting types yet.": {"cs":"Zatím žádné typy schůzek.","de":"Noch keine Termintypen.","fr":"Aucun type de réunion pour l'instant.","it":"Ancora nessun tipo di riunione.","pl":"Brak typów spotkań.","pt":"Nenhum tipo de reunião ainda.","uk":"Типів зустрічей поки немає."},
  "Inactive: not offered anywhere until you turn it back on.": {"cs":"Neaktivní: nikde se nenabízí, dokud jej znovu nezapnete.","de":"Inaktiv: wird nirgends angeboten, bis Sie ihn wieder einschalten.","fr":"Inactif : proposé nulle part tant que vous ne le réactivez pas.","it":"Inattivo: non viene proposto da nessuna parte finché non lo riattivi.","pl":"Nieaktywny: nigdzie nie jest oferowany, dopóki go nie włączysz.","pt":"Inativo: não é oferecido em lugar nenhum até você reativá-lo.","uk":"Неактивний: ніде не пропонується, доки ви знову його не ввімкнете."},
  "Delete page": {"cs":"Smazat stránku","de":"Seite löschen","fr":"Supprimer la page","it":"Elimina pagina","pl":"Usuń stronę","pt":"Excluir página","uk":"Видалити сторінку"},
  "Booking page saved": {"cs":"Rezervační stránka byla uložena","de":"Buchungsseite gespeichert","fr":"Page de réservation enregistrée","it":"Pagina di prenotazione salvata","pl":"Zapisano stronę rezerwacji","pt":"Página de agendamento salva","uk":"Сторінку бронювання збережено"},
  "Delete booking page": {"cs":"Smazat rezervační stránku","de":"Buchungsseite löschen","fr":"Supprimer la page de réservation","it":"Elimina pagina di prenotazione","pl":"Usuń stronę rezerwacji","pt":"Excluir página de agendamento","uk":"Видалити сторінку бронювання"},
  "Delete %{address}? Bookings made through it keep working and show your main page's look. Its colours and uploaded backgrounds are removed.": {"cs":"Smazat %{address}? Rezervace vytvořené přes ni fungují dál a zobrazí se ve vzhledu vaší hlavní stránky. Její barvy a nahraná pozadí budou odstraněny.","de":"%{address} löschen? Darüber gemachte Buchungen funktionieren weiter und erscheinen im Look Ihrer Hauptseite. Die Farben und hochgeladenen Hintergründe der Seite werden entfernt.","fr":"Supprimer %{address} ? Les réservations faites par cette page continuent de fonctionner et prennent l'apparence de votre page principale. Ses couleurs et arrière-plans téléversés sont supprimés.","it":"Eliminare %{address}? Le prenotazioni fatte tramite questa pagina restano valide e mostrano l'aspetto della tua pagina principale. I suoi colori e gli sfondi caricati vengono rimossi.","pl":"Usunąć %{address}? Rezerwacje dokonane przez tę stronę nadal działają i przyjmą wygląd strony głównej. Jej kolory i przesłane tła zostaną usunięte.","pt":"Excluir %{address}? Os agendamentos feitos por ela continuam funcionando e passam a ter a aparência da sua página principal. As cores e os fundos enviados da página são removidos.","uk":"Видалити %{address}? Бронювання, зроблені через неї, працюватимуть і далі та матимуть вигляд вашої головної сторінки. Її кольори та завантажені фони буде видалено."},
  "Booking page deleted": {"cs":"Rezervační stránka byla smazána","de":"Buchungsseite gelöscht","fr":"Page de réservation supprimée","it":"Pagina di prenotazione eliminata","pl":"Usunięto stronę rezerwacji","pt":"Página de agendamento excluída","uk":"Сторінку бронювання видалено"},
  "Could not delete the booking page. Please try again.": {"cs":"Rezervační stránku se nepodařilo smazat. Zkuste to prosím znovu.","de":"Die Buchungsseite konnte nicht gelöscht werden. Bitte versuchen Sie es erneut.","fr":"Impossible de supprimer la page de réservation. Veuillez réessayer.","it":"Impossibile eliminare la pagina di prenotazione. Riprova.","pl":"Nie udało się usunąć strony rezerwacji. Spróbuj ponownie.","pt":"Não foi possível excluir a página de agendamento. Tente novamente.","uk":"Не вдалося видалити сторінку бронювання. Спробуйте ще раз."},
 },
 "dashboard_meeting_form": {
  "Show on %{address}": {"cs":"Zobrazit na %{address}","de":"Auf %{address} anzeigen","fr":"Afficher sur %{address}","it":"Mostra su %{address}","pl":"Pokazuj na %{address}","pt":"Mostrar em %{address}","uk":"Показувати на %{address}"},
  "On no booking page: bookable only through its direct link.": {"cs":"Na žádné rezervační stránce: rezervovatelné jen přes přímý odkaz.","de":"Auf keiner Buchungsseite: nur über den direkten Link buchbar.","fr":"Sur aucune page de réservation : réservable uniquement via son lien direct.","it":"In nessuna pagina di prenotazione: prenotabile solo tramite il link diretto.","pl":"Na żadnej stronie rezerwacji: dostępny tylko przez bezpośredni link.","pt":"Em nenhuma página de agendamento: só pode ser agendado pelo link direto.","uk":"На жодній сторінці бронювання: доступно лише за прямим посиланням."},
 },
 "dashboard_embed": {
  "Booking page": {"cs":"Rezervační stránka","de":"Buchungsseite","fr":"Page de réservation","it":"Pagina di prenotazione","pl":"Strona rezerwacji","pt":"Página de agendamento","uk":"Сторінка бронювання"},
 },
 "errors": {
  "Use 3 to 30 lowercase letters, numbers, hyphens or underscores, starting with a letter or number": {"cs":"Použijte 3 až 30 malých písmen, číslic, pomlček nebo podtržítek; na začátku písmeno nebo číslice","de":"Verwenden Sie 3 bis 30 Kleinbuchstaben, Ziffern, Bindestriche oder Unterstriche, beginnend mit einem Buchstaben oder einer Ziffer","fr":"Utilisez 3 à 30 lettres minuscules, chiffres, tirets ou tirets bas, en commençant par une lettre ou un chiffre","it":"Usa da 3 a 30 lettere minuscole, numeri, trattini o trattini bassi, iniziando con una lettera o un numero","pl":"Użyj od 3 do 30 małych liter, cyfr, łączników lub podkreśleń, zaczynając od litery lub cyfry","pt":"Use de 3 a 30 letras minúsculas, números, hifens ou sublinhados, começando com uma letra ou um número","uk":"Використовуйте від 3 до 30 малих літер, цифр, дефісів або підкреслень, починаючи з літери чи цифри"},
 },
}

for domain, entries in T.items():
    for locale in ["cs", "de", "fr", "it", "pl", "pt", "uk"]:
        path = Path(f"priv/gettext/{locale}/LC_MESSAGES/{domain}.po")
        blocks = path.read_text().split("\n\n")
        for i, block in enumerate(blocks):
            m = re.search(r'^msgid "(.*)"\nmsgstr ""$', block, re.M)
            if m and m.group(1) in entries:
                text = entries[m.group(1)][locale].replace('"', '\\"')
                blocks[i] = block[: m.start()] + f'msgid "{m.group(1)}"\nmsgstr "{text}"' + block[m.end():]
                print(f"{locale}/{domain}: {m.group(1)[:50]}")
        path.write_text("\n\n".join(blocks))
```

If extraction wrapped a long msgid over several lines (`msgid ""` followed by continuation strings), the script will not match it; fill those by hand from the table above.

- [ ] **Step 4: Check completeness**

Run (mix): `test test/tymeslot_web/gettext_completeness_test.exs`
Expected: pass. A failure names the locale, domain and msgid still empty or fuzzy; fill it from the table.

Run (mix, `MIX_ENV=dev`): `gettext.extract --check-up-to-date`
Expected: no output, exit 0.

- [ ] **Step 5: Commit**

```bash
git add priv/gettext
git commit -m "chore(i18n): translate the booking pages strings"
```

---

### Task 14: Full verification

**Files:**
- Modify: `docs/superpowers/specs/2026-10-09-booking-pages-design.md` (status line)

- [ ] **Step 1: Run every gate**

Run (mix, `MIX_ENV=dev`), each in turn, and read each output:
- `compile --warnings-as-errors --force`
- `format --check-formatted`
- `credo --strict`
- `gettext.extract --check-up-to-date`
- `deps.unlock --check-unused`
- `excellent_migrations.check_safety`

Run (mix, `MIX_ENV=test`): `compile --warnings-as-errors --force`
Expected: all clean. For credo's `LargeModules`, check `wc -l lib/tymeslot/bookings/policy.ex` (at most 650) and every file this plan grew.

- [ ] **Step 2: Run the full suite**

Run (mix): `test`
Expected: everything passes, apart from the known load flake `SeatLockedEventsTest` "a booking nobody holds a seat on moves when dropped" (re-run that file alone to confirm it passes). Report the exact counts.

- [ ] **Step 3: Exercise the Review Focus once by hand**

If a dev database is available: create a page, tick one meeting type, open `/<page>` and `/<username>` side by side, change the page's theme and texts, delete the page, and confirm `/<username>` never changed. If none is available here, say so in the report instead.

- [ ] **Step 4: Mark the spec implemented**

In the spec, change `**Status:** approved design, not yet implemented` to ``**Status:** implemented on `feature/booking-pages` ``.

- [ ] **Step 5: Commit and stop the database**

```bash
git add docs/superpowers/specs/2026-10-09-booking-pages-design.md
git commit -m "docs(booking-pages): mark the booking pages spec implemented"
docker stop tymeslot-test-pg
```
