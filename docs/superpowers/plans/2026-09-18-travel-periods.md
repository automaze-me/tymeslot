# Travel Periods Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a host declare date ranges during which a different timezone and different weekly hours apply, resolved per slot date so a booking made while away for a post-return date still offers home availability.

**Architecture:** Two new tables (`travel_periods`, `travel_period_days`) and one new resolver, `Availability.OwnerFrame`, which answers "which zone and which hours are in effect on date D". The resolver is called inside `BusinessHours.get_business_hours_in_timezone/5`, which every availability path already funnels through, so the booking page and the booking-time re-check inherit trips structurally rather than each remembering to. Trips reach that function through `config[:travel_periods]`, prefetched once per window by a single resolver shared by both config builders.

**Tech Stack:** Elixir ~> 1.20, Phoenix 1.8, LiveView 1.1, Ecto/PostgreSQL 14+, ExUnit with ExMachina factories, `tz` for IANA data.

**Spec:** `docs/superpowers/specs/2026-09-18-travel-periods-design.md`

## Global Constraints

- **Repo calls belong in `*_queries.ex` modules.** Only `Repo.transaction`, `Repo.rollback` and `Repo.preload` are permitted in a domain context module.
- **Generate migrations** with `mix ecto.gen.migration <name>`; never hand-create migration files.
- **No queries in `mount/3`** — defer data loading to `handle_params/3`.
- **HEEx comments only** (`<%!-- --%>`) in `.heex` files and `~H` sigils; never HTML comments.
- **Every test module** declares at least one `@moduletag` from `test/support/tag_taxonomy.ex`. This feature uses `:availability` plus `:schema`, `:queries`, `:unit` or `:live`.
- **Module aliases** at the top of the file, alphabetically ordered.
- **Commits** follow Conventional Commits. **No DCO sign-off** (`-s`) — this is a private-use fork. No Claude attribution footers or trailers.
- **`owner_timezone` keeps its name** throughout. Its meaning changes from "the effective zone" to "the home-zone fallback"; a rename across every call site is the worst kind of diff on a fork that rebases against upstream indefinitely.
- **Policy never comes from a trip.** Buffer, notice and horizon always come from the meeting type's resolved schedule.
- **Definition of done** for the whole plan: `mix test` 0 failures, `mix credo --strict` clean, `mix dialyzer` no warnings, `mix format --check-formatted`.
- **Minimise edits to existing files.** Prefer new modules; keep each edit to an existing file small and local.

---

## File Structure

**New files (no rebase conflict surface):**

| File | Responsibility |
| --- | --- |
| `priv/repo/migrations/*_create_travel_periods.exs` | Both tables, in one generated migration |
| `lib/tymeslot/availability/travel_period_schema.ex` | The trip: date range, zone, label |
| `lib/tymeslot/availability/travel_period_day_schema.ex` | One weekday's hours within a trip |
| `lib/tymeslot/availability/travel_period_queries.ex` | Every `Repo` call for trips |
| `lib/tymeslot/availability/travel.ex` | Public context: CRUD, overlap validation, cache invalidation |
| `lib/tymeslot/availability/owner_frame.ex` | Resolves zone + hours for one date |
| `lib/tymeslot_web/live/dashboard/availability/travel_section.ex` | Trip list UI |
| `lib/tymeslot_web/live/dashboard/availability/travel_form.ex` | Trip editor UI |

**Modified files, load-bearing:**

| File | Change |
| --- | --- |
| `lib/tymeslot/availability/business_hours.ex` | Resolve the frame per date |
| `lib/tymeslot/availability/calculate.ex` | `prefetch_travel_periods/4`, config typedoc |
| `lib/tymeslot/bookings/policy.ex` | Trips into `scheduling_config/2` |
| `lib/tymeslot_web/live/scheduling/availability_helpers.ex` | Trips into the display path |

**Modified files, display and UI:**

| File | Change |
| --- | --- |
| `lib/tymeslot/profiles/timezone.ex` | `timezone_on/2` |
| `lib/tymeslot/emails/appointment_builder.ex` | Owner zone from the meeting's date |
| `lib/tymeslot/emails/email_service/calendar_emails.ex` | Same |
| `lib/tymeslot_web/live/dashboard/schedule_settings_component.ex` | Mount the Travel section |
| `test/support/factory.ex` | `:travel_period`, `:travel_period_day` |

---

# Stage 1 — Schema and queries

Independently verifiable: trips can be stored, read back for a window, and overlapping trips are refused. Nothing in the availability engine changes yet.

### Task 1: Trip schemas, migration and factories

**Files:**
- Create: `priv/repo/migrations/<timestamp>_create_travel_periods.exs`
- Create: `lib/tymeslot/availability/travel_period_schema.ex`
- Create: `lib/tymeslot/availability/travel_period_day_schema.ex`
- Modify: `test/support/factory.ex`
- Test: `test/tymeslot/availability/travel_period_schema_test.exs`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `TravelPeriodSchema.changeset(%TravelPeriodSchema{}, map()) :: Ecto.Changeset.t()` — fields `:profile_id`, `:label`, `:start_date`, `:end_date`, `:timezone`; `has_many :days`
  - `TravelPeriodDaySchema.changeset(%TravelPeriodDaySchema{}, map()) :: Ecto.Changeset.t()` — fields `:travel_period_id`, `:day_of_week`, `:is_available`, `:start_time`, `:end_time`
  - Factories `:travel_period` and `:travel_period_day`

- [ ] **Step 1: Write the failing test**

Create `test/tymeslot/availability/travel_period_schema_test.exs`:

```elixir
defmodule Tymeslot.Availability.TravelPeriodSchemaTest do
  use Tymeslot.DataCase, async: true

  @moduletag :availability
  @moduletag :schema

  import Tymeslot.Factory

  alias Tymeslot.Availability.TravelPeriodDaySchema
  alias Tymeslot.Availability.TravelPeriodSchema

  describe "changeset/2" do
    test "accepts a valid trip" do
      profile = insert(:profile)

      changeset =
        TravelPeriodSchema.changeset(%TravelPeriodSchema{}, %{
          profile_id: profile.id,
          label: "Berlin, spring",
          start_date: ~D[2027-03-14],
          end_date: ~D[2027-03-28],
          timezone: "Europe/Berlin"
        })

      assert changeset.valid?
      assert {:ok, period} = Repo.insert(changeset)
      assert period.timezone == "Europe/Berlin"
    end

    test "rejects an unknown timezone" do
      profile = insert(:profile)

      changeset =
        TravelPeriodSchema.changeset(%TravelPeriodSchema{}, %{
          profile_id: profile.id,
          label: "Nowhere",
          start_date: ~D[2027-03-14],
          end_date: ~D[2027-03-28],
          timezone: "Mars/Olympus_Mons"
        })

      refute changeset.valid?
      assert "is not a valid timezone" in errors_on(changeset).timezone
    end

    test "rejects an end date before the start date" do
      profile = insert(:profile)

      changeset =
        TravelPeriodSchema.changeset(%TravelPeriodSchema{}, %{
          profile_id: profile.id,
          label: "Backwards",
          start_date: ~D[2027-03-28],
          end_date: ~D[2027-03-14],
          timezone: "Europe/Berlin"
        })

      refute changeset.valid?
      assert "must be on or after the start date" in errors_on(changeset).end_date
    end

    test "accepts a single-day trip" do
      profile = insert(:profile)

      changeset =
        TravelPeriodSchema.changeset(%TravelPeriodSchema{}, %{
          profile_id: profile.id,
          label: "Day trip",
          start_date: ~D[2027-03-14],
          end_date: ~D[2027-03-14],
          timezone: "Europe/Berlin"
        })

      assert changeset.valid?
    end
  end

  describe "TravelPeriodDaySchema.changeset/2" do
    test "requires hours when the day is available" do
      period = insert(:travel_period)

      changeset =
        TravelPeriodDaySchema.changeset(%TravelPeriodDaySchema{}, %{
          travel_period_id: period.id,
          day_of_week: 3,
          is_available: true
        })

      refute changeset.valid?
      assert "are required when day is available" in errors_on(changeset).start_time
    end

    test "rejects an end time at or before the start time" do
      period = insert(:travel_period)

      changeset =
        TravelPeriodDaySchema.changeset(%TravelPeriodDaySchema{}, %{
          travel_period_id: period.id,
          day_of_week: 3,
          is_available: true,
          start_time: ~T[16:00:00],
          end_time: ~T[10:00:00]
        })

      refute changeset.valid?
    end

    test "rejects a day_of_week outside 1..7" do
      period = insert(:travel_period)

      changeset =
        TravelPeriodDaySchema.changeset(%TravelPeriodDaySchema{}, %{
          travel_period_id: period.id,
          day_of_week: 8,
          is_available: false
        })

      refute changeset.valid?
    end

    test "accepts one day per weekday but not two" do
      period = insert(:travel_period)

      attrs = %{
        travel_period_id: period.id,
        day_of_week: 3,
        is_available: true,
        start_time: ~T[10:00:00],
        end_time: ~T[16:00:00]
      }

      assert {:ok, _day} = Repo.insert(TravelPeriodDaySchema.changeset(%TravelPeriodDaySchema{}, attrs))

      assert {:error, changeset} =
               Repo.insert(TravelPeriodDaySchema.changeset(%TravelPeriodDaySchema{}, attrs))

      assert "has already been taken" in errors_on(changeset).travel_period_id
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/tymeslot/availability/travel_period_schema_test.exs`
Expected: FAIL — `Tymeslot.Availability.TravelPeriodSchema is not available`

- [ ] **Step 3: Generate the migration**

Run: `mix ecto.gen.migration create_travel_periods`

Replace the generated file's contents with:

```elixir
defmodule Tymeslot.Repo.Migrations.CreateTravelPeriods do
  use Ecto.Migration

  # excellent_migrations:safety-assured-for-this-file column_reference_added
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  # Both tables are brand new, so their defaults, foreign keys, indexes and
  # check constraint cannot rewrite or lock any existing row.

  def change do
    create table(:travel_periods) do
      add(:profile_id, references(:profiles, on_delete: :delete_all), null: false)
      add(:label, :string, null: false)
      add(:start_date, :date, null: false)
      add(:end_date, :date, null: false)
      add(:timezone, :string, null: false)

      timestamps(type: :utc_datetime)
    end

    create(index(:travel_periods, [:profile_id, :start_date, :end_date]))

    create(
      constraint(:travel_periods, :travel_periods_end_on_or_after_start,
        check: "end_date >= start_date"
      )
    )

    create table(:travel_period_days) do
      add(:travel_period_id, references(:travel_periods, on_delete: :delete_all), null: false)
      add(:day_of_week, :integer, null: false)
      add(:is_available, :boolean, null: false, default: false)
      add(:start_time, :time)
      add(:end_time, :time)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:travel_period_days, [:travel_period_id, :day_of_week]))
  end
end
```

- [ ] **Step 4: Write `TravelPeriodSchema`**

Create `lib/tymeslot/availability/travel_period_schema.ex`:

```elixir
defmodule Tymeslot.Availability.TravelPeriodSchema do
  @moduledoc """
  A date range during which the profile's timezone and weekly hours differ.

  A trip is the exception layered over the profile's home zone, not a
  replacement for it: with no trips, availability resolves exactly as it did
  before this table existed. Dates are inclusive on both ends and are whole
  calendar dates, so one date never spans two zones. Travel days are not
  modelled — a flight is a timed event on a synced calendar and already blocks
  those hours through ordinary conflict checking.

  Trips carry no scheduling policy. Buffer, notice period and booking horizon
  always come from the meeting type's resolved schedule, so adding a trip can
  never silently rewrite them.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Tymeslot.Availability.TravelPeriodDaySchema
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Timezones

  @type t :: %__MODULE__{
          id: integer() | nil,
          profile_id: integer() | nil,
          label: String.t() | nil,
          start_date: Date.t() | nil,
          end_date: Date.t() | nil,
          timezone: String.t() | nil,
          profile: ProfileSchema.t() | Ecto.Association.NotLoaded.t(),
          days: [TravelPeriodDaySchema.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @label_max_length 60

  schema "travel_periods" do
    field(:label, :string)
    field(:start_date, :date)
    field(:end_date, :date)
    field(:timezone, :string)

    belongs_to(:profile, ProfileSchema)
    has_many(:days, TravelPeriodDaySchema, foreign_key: :travel_period_id)

    timestamps(type: :utc_datetime)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(period, attrs) do
    period
    |> cast(attrs, [:profile_id, :label, :start_date, :end_date, :timezone])
    |> validate_required([:profile_id, :label, :start_date, :end_date, :timezone])
    |> validate_length(:label, max: @label_max_length)
    |> validate_timezone()
    |> validate_date_order()
    |> foreign_key_constraint(:profile_id)
    |> check_constraint(:end_date,
      name: :travel_periods_end_on_or_after_start,
      message: "must be on or after the start date"
    )
  end

  @doc """
  The longest a trip label may be.
  """
  @spec label_max_length() :: pos_integer()
  def label_max_length, do: @label_max_length

  # Reuses the profile's own validator so an invalid zone is refused the same
  # way in both places, rather than one accepting what the other rejects.
  defp validate_timezone(changeset) do
    case get_change(changeset, :timezone) do
      nil ->
        changeset

      timezone ->
        if Timezones.valid?(timezone) do
          changeset
        else
          add_error(changeset, :timezone, "is not a valid timezone")
        end
    end
  end

  # Validated here as well as by the check constraint: the changeset error
  # reaches the form field, whereas the constraint only fires at insert time
  # and is the backstop for a write that bypasses this function.
  defp validate_date_order(changeset) do
    start_date = get_field(changeset, :start_date)
    end_date = get_field(changeset, :end_date)

    if is_struct(start_date, Date) and is_struct(end_date, Date) and
         Date.compare(end_date, start_date) == :lt do
      add_error(changeset, :end_date, "must be on or after the start date")
    else
      changeset
    end
  end
end
```

- [ ] **Step 5: Write `TravelPeriodDaySchema`**

Create `lib/tymeslot/availability/travel_period_day_schema.ex`:

```elixir
defmodule Tymeslot.Availability.TravelPeriodDaySchema do
  @moduledoc """
  One weekday's bookable hours within a travel period.

  Deliberately the same shape as `Tymeslot.Availability.WeeklyAvailabilitySchema`
  — same `day_of_week` numbering, same `is_available` plus start/end pair, same
  validation of hours — so the editor components and the day-shape logic are
  shared rather than parallel. Breaks are not modelled yet; `OwnerFrame` reports
  `breaks: []` for a trip day.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Tymeslot.Availability.TravelPeriodSchema
  alias Tymeslot.ChangesetValidators.TimeOrder

  @type t :: %__MODULE__{
          id: integer() | nil,
          travel_period_id: integer() | nil,
          day_of_week: integer() | nil,
          is_available: boolean(),
          start_time: Time.t() | nil,
          end_time: Time.t() | nil,
          travel_period: TravelPeriodSchema.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "travel_period_days" do
    field(:day_of_week, :integer)
    field(:is_available, :boolean, default: false)
    field(:start_time, :time)
    field(:end_time, :time)

    belongs_to(:travel_period, TravelPeriodSchema)

    timestamps(type: :utc_datetime)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(day, attrs) do
    day
    |> cast(attrs, [:travel_period_id, :day_of_week, :is_available, :start_time, :end_time])
    |> validate_required([:travel_period_id, :day_of_week])
    |> validate_inclusion(:day_of_week, 1..7,
      message: "must be between 1 (Monday) and 7 (Sunday)"
    )
    |> validate_times()
    |> unique_constraint([:travel_period_id, :day_of_week])
    |> foreign_key_constraint(:travel_period_id)
  end

  defp validate_times(changeset) do
    if get_field(changeset, :is_available) do
      changeset
      |> validate_required([:start_time, :end_time],
        message: "are required when day is available"
      )
      |> TimeOrder.validate_time_order(:start_time, :end_time)
    else
      changeset
    end
  end
end
```

- [ ] **Step 6: Add the factories**

In `test/support/factory.ex`, add these two factories next to `availability_override_factory/0`, and add `alias Tymeslot.Availability.TravelPeriodDaySchema` and `alias Tymeslot.Availability.TravelPeriodSchema` to the alias block in alphabetical position:

```elixir
  @spec travel_period_factory() :: Tymeslot.Availability.TravelPeriodSchema.t()
  def travel_period_factory do
    %TravelPeriodSchema{
      label: sequence(:travel_period_label, &"Trip #{&1}"),
      start_date: Date.add(Date.utc_today(), 30),
      end_date: Date.add(Date.utc_today(), 44),
      timezone: "Europe/Berlin",
      profile: build(:profile)
    }
  end

  @spec travel_period_day_factory() :: Tymeslot.Availability.TravelPeriodDaySchema.t()
  def travel_period_day_factory do
    %TravelPeriodDaySchema{
      # Wednesday
      day_of_week: 3,
      is_available: true,
      start_time: ~T[10:00:00],
      end_time: ~T[16:00:00],
      travel_period: build(:travel_period)
    }
  end
```

- [ ] **Step 7: Migrate and run the tests**

Run: `mix ecto.migrate && mix test test/tymeslot/availability/travel_period_schema_test.exs`
Expected: PASS, 8 tests

- [ ] **Step 8: Commit**

```bash
git add priv/repo/migrations lib/tymeslot/availability/travel_period_schema.ex \
        lib/tymeslot/availability/travel_period_day_schema.ex \
        test/support/factory.ex \
        test/tymeslot/availability/travel_period_schema_test.exs
git commit -m "feat(availability): add travel period schemas"
```

---

### Task 2: Trip queries

**Files:**
- Create: `lib/tymeslot/availability/travel_period_queries.ex`
- Test: `test/tymeslot/availability/travel_period_queries_test.exs`

**Interfaces:**
- Consumes: `TravelPeriodSchema`, `TravelPeriodDaySchema` from Task 1
- Produces:
  - `list_overlapping(profile_id :: integer(), Date.t(), Date.t()) :: [TravelPeriodSchema.t()]` — `:days` preloaded, ordered by `start_date`
  - `list_by_profile(profile_id :: integer()) :: [TravelPeriodSchema.t()]` — `:days` preloaded, ordered by `start_date`
  - `overlapping(profile_id :: integer(), Date.t(), Date.t(), exclude_id :: integer() | nil) :: [TravelPeriodSchema.t()]`
  - `insert_period(Ecto.Changeset.t()) :: {:ok, TravelPeriodSchema.t()} | {:error, Ecto.Changeset.t()}`
  - `update_period(Ecto.Changeset.t()) :: {:ok, TravelPeriodSchema.t()} | {:error, Ecto.Changeset.t()}`
  - `delete_period(TravelPeriodSchema.t()) :: {:ok, TravelPeriodSchema.t()} | {:error, Ecto.Changeset.t()}`
  - `upsert_day(map()) :: {:ok, TravelPeriodDaySchema.t()} | {:error, Ecto.Changeset.t()}`

- [ ] **Step 1: Write the failing test**

Create `test/tymeslot/availability/travel_period_queries_test.exs`:

```elixir
defmodule Tymeslot.Availability.TravelPeriodQueriesTest do
  use Tymeslot.DataCase, async: true

  @moduletag :availability
  @moduletag :queries

  import Tymeslot.Factory

  alias Tymeslot.Availability.TravelPeriodQueries

  describe "list_overlapping/3" do
    test "returns a trip that overlaps the window and preloads its days" do
      profile = insert(:profile)

      period =
        insert(:travel_period,
          profile: profile,
          start_date: ~D[2027-03-14],
          end_date: ~D[2027-03-28]
        )

      insert(:travel_period_day, travel_period: period, day_of_week: 3)

      assert [found] =
               TravelPeriodQueries.list_overlapping(profile.id, ~D[2027-03-01], ~D[2027-03-31])

      assert found.id == period.id
      assert [day] = found.days
      assert day.day_of_week == 3
    end

    test "includes a trip that only partially overlaps at each edge" do
      profile = insert(:profile)

      insert(:travel_period,
        profile: profile,
        start_date: ~D[2027-02-25],
        end_date: ~D[2027-03-02],
        label: "straddles the start"
      )

      insert(:travel_period,
        profile: profile,
        start_date: ~D[2027-03-30],
        end_date: ~D[2027-04-04],
        label: "straddles the end"
      )

      found = TravelPeriodQueries.list_overlapping(profile.id, ~D[2027-03-01], ~D[2027-03-31])

      assert length(found) == 2
    end

    test "excludes a trip entirely outside the window" do
      profile = insert(:profile)

      insert(:travel_period,
        profile: profile,
        start_date: ~D[2027-05-01],
        end_date: ~D[2027-05-10]
      )

      assert [] =
               TravelPeriodQueries.list_overlapping(profile.id, ~D[2027-03-01], ~D[2027-03-31])
    end

    test "excludes another profile's trip" do
      profile = insert(:profile)
      other = insert(:profile)

      insert(:travel_period,
        profile: other,
        start_date: ~D[2027-03-14],
        end_date: ~D[2027-03-28]
      )

      assert [] =
               TravelPeriodQueries.list_overlapping(profile.id, ~D[2027-03-01], ~D[2027-03-31])
    end
  end

  describe "overlapping/4" do
    test "finds a colliding trip" do
      profile = insert(:profile)

      insert(:travel_period,
        profile: profile,
        start_date: ~D[2027-03-14],
        end_date: ~D[2027-03-28]
      )

      assert [_collision] =
               TravelPeriodQueries.overlapping(profile.id, ~D[2027-03-20], ~D[2027-04-02], nil)
    end

    test "treats touching dates as overlapping, since both ends are inclusive" do
      profile = insert(:profile)

      insert(:travel_period,
        profile: profile,
        start_date: ~D[2027-03-14],
        end_date: ~D[2027-03-28]
      )

      assert [_collision] =
               TravelPeriodQueries.overlapping(profile.id, ~D[2027-03-28], ~D[2027-04-02], nil)
    end

    test "excludes the trip being edited" do
      profile = insert(:profile)

      period =
        insert(:travel_period,
          profile: profile,
          start_date: ~D[2027-03-14],
          end_date: ~D[2027-03-28]
        )

      assert [] =
               TravelPeriodQueries.overlapping(
                 profile.id,
                 ~D[2027-03-15],
                 ~D[2027-03-29],
                 period.id
               )
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/tymeslot/availability/travel_period_queries_test.exs`
Expected: FAIL — `Tymeslot.Availability.TravelPeriodQueries is not available`

- [ ] **Step 3: Write the queries module**

Create `lib/tymeslot/availability/travel_period_queries.ex`:

```elixir
defmodule Tymeslot.Availability.TravelPeriodQueries do
  @moduledoc """
  Query interface for travel periods.

  Trips hang off a profile rather than an availability schedule, because a trip
  applies to every meeting type for the dates it covers. That is why the
  availability engine cannot prefetch them through
  `Calculate.prefetch_schedule_data/4`, which is keyed by `schedule_id` and
  returns early when there is none.

  `:days` is preloaded by every read that the availability engine consumes.
  `OwnerFrame` treats an unloaded association as "no hours", which fails closed
  — a trip whose days did not load offers nothing rather than falling back to
  home hours in a foreign zone.
  """
  import Ecto.Query, warn: false

  alias Tymeslot.Availability.TravelPeriodDaySchema
  alias Tymeslot.Availability.TravelPeriodSchema
  alias Tymeslot.Repo

  @doc """
  Trips for a profile that overlap the inclusive window, `:days` preloaded.
  """
  @spec list_overlapping(integer(), Date.t(), Date.t()) :: [TravelPeriodSchema.t()]
  def list_overlapping(profile_id, start_date, end_date) do
    TravelPeriodSchema
    |> where([p], p.profile_id == ^profile_id)
    |> where([p], p.start_date <= ^end_date and p.end_date >= ^start_date)
    |> order_by(asc: :start_date)
    |> preload(:days)
    |> Repo.all()
  end

  @doc """
  Every trip a profile owns, earliest first, `:days` preloaded.
  """
  @spec list_by_profile(integer()) :: [TravelPeriodSchema.t()]
  def list_by_profile(profile_id) do
    TravelPeriodSchema
    |> where([p], p.profile_id == ^profile_id)
    |> order_by(asc: :start_date)
    |> preload(:days)
    |> Repo.all()
  end

  @doc """
  Trips colliding with the given range, optionally ignoring one by id.

  Both ends of a trip are inclusive, so ranges that merely touch do collide:
  a date cannot belong to two trips, because it cannot resolve to two zones.
  """
  @spec overlapping(integer(), Date.t(), Date.t(), integer() | nil) :: [TravelPeriodSchema.t()]
  def overlapping(profile_id, start_date, end_date, exclude_id) do
    TravelPeriodSchema
    |> where([p], p.profile_id == ^profile_id)
    |> where([p], p.start_date <= ^end_date and p.end_date >= ^start_date)
    |> exclude_id(exclude_id)
    |> Repo.all()
  end

  @doc """
  Inserts a trip from a prepared changeset.
  """
  @spec insert_period(Ecto.Changeset.t()) ::
          {:ok, TravelPeriodSchema.t()} | {:error, Ecto.Changeset.t()}
  def insert_period(changeset), do: Repo.insert(changeset)

  @doc """
  Updates a trip from a prepared changeset.
  """
  @spec update_period(Ecto.Changeset.t()) ::
          {:ok, TravelPeriodSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_period(changeset), do: Repo.update(changeset)

  @doc """
  Deletes a trip. Its days go with it via `on_delete: :delete_all`.
  """
  @spec delete_period(TravelPeriodSchema.t()) ::
          {:ok, TravelPeriodSchema.t()} | {:error, Ecto.Changeset.t()}
  def delete_period(period), do: Repo.delete(period)

  @doc """
  Inserts or replaces one weekday's hours within a trip.
  """
  @spec upsert_day(map()) :: {:ok, TravelPeriodDaySchema.t()} | {:error, Ecto.Changeset.t()}
  def upsert_day(attrs) do
    %TravelPeriodDaySchema{}
    |> TravelPeriodDaySchema.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:is_available, :start_time, :end_time, :updated_at]},
      conflict_target: [:travel_period_id, :day_of_week]
    )
  end

  defp exclude_id(query, nil), do: query
  defp exclude_id(query, id), do: where(query, [p], p.id != ^id)
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/tymeslot/availability/travel_period_queries_test.exs`
Expected: PASS, 7 tests

- [ ] **Step 5: Commit**

```bash
git add lib/tymeslot/availability/travel_period_queries.ex \
        test/tymeslot/availability/travel_period_queries_test.exs
git commit -m "feat(availability): add travel period queries"
```

---

### Task 3: The `Travel` context

**Files:**
- Create: `lib/tymeslot/availability/travel.ex`
- Test: `test/tymeslot/availability/travel_test.exs`

**Interfaces:**
- Consumes: `TravelPeriodQueries` from Task 2
- Produces:
  - `Travel.for_window(profile_id :: integer(), Date.t(), Date.t()) :: [TravelPeriodSchema.t()]` — the single trip resolver both config builders call
  - `Travel.list_for_profile(profile_id :: integer()) :: [TravelPeriodSchema.t()]`
  - `Travel.create_period(ProfileSchema.t(), map()) :: {:ok, TravelPeriodSchema.t()} | {:error, Ecto.Changeset.t()}`
  - `Travel.update_period(ProfileSchema.t(), TravelPeriodSchema.t(), map()) :: {:ok, TravelPeriodSchema.t()} | {:error, Ecto.Changeset.t()}`
  - `Travel.delete_period(ProfileSchema.t(), TravelPeriodSchema.t()) :: {:ok, TravelPeriodSchema.t()} | {:error, Ecto.Changeset.t()}`
  - `Travel.set_day(ProfileSchema.t(), TravelPeriodSchema.t(), map()) :: {:ok, TravelPeriodDaySchema.t()} | {:error, Ecto.Changeset.t()}`

- [ ] **Step 1: Write the failing test**

Create `test/tymeslot/availability/travel_test.exs`:

```elixir
defmodule Tymeslot.Availability.TravelTest do
  use Tymeslot.DataCase, async: true

  @moduletag :availability
  @moduletag :unit

  import Tymeslot.Factory

  alias Tymeslot.Availability.Travel

  describe "create_period/2" do
    test "creates a trip" do
      profile = insert(:profile)

      assert {:ok, period} =
               Travel.create_period(profile, %{
                 label: "Berlin, spring",
                 start_date: ~D[2027-03-14],
                 end_date: ~D[2027-03-28],
                 timezone: "Europe/Berlin"
               })

      assert period.profile_id == profile.id
      assert period.timezone == "Europe/Berlin"
    end

    test "refuses a trip overlapping an existing one" do
      profile = insert(:profile)

      insert(:travel_period,
        profile: profile,
        start_date: ~D[2027-03-14],
        end_date: ~D[2027-03-28]
      )

      assert {:error, changeset} =
               Travel.create_period(profile, %{
                 label: "Overlaps",
                 start_date: ~D[2027-03-20],
                 end_date: ~D[2027-04-02],
                 timezone: "Europe/Paris"
               })

      assert "overlaps an existing trip" in errors_on(changeset).start_date
    end

    test "allows a trip abutting an existing one without overlapping" do
      profile = insert(:profile)

      insert(:travel_period,
        profile: profile,
        start_date: ~D[2027-03-14],
        end_date: ~D[2027-03-28]
      )

      assert {:ok, _period} =
               Travel.create_period(profile, %{
                 label: "The day after",
                 start_date: ~D[2027-03-29],
                 end_date: ~D[2027-04-02],
                 timezone: "Europe/Paris"
               })
    end

    test "ignores another profile's trips when checking overlap" do
      profile = insert(:profile)
      other = insert(:profile)

      insert(:travel_period,
        profile: other,
        start_date: ~D[2027-03-14],
        end_date: ~D[2027-03-28]
      )

      assert {:ok, _period} =
               Travel.create_period(profile, %{
                 label: "Same dates, different person",
                 start_date: ~D[2027-03-14],
                 end_date: ~D[2027-03-28],
                 timezone: "Europe/Berlin"
               })
    end
  end

  describe "update_period/3" do
    test "does not treat the trip being edited as an overlap with itself" do
      profile = insert(:profile)

      period =
        insert(:travel_period,
          profile: profile,
          start_date: ~D[2027-03-14],
          end_date: ~D[2027-03-28]
        )

      assert {:ok, updated} =
               Travel.update_period(profile, period, %{end_date: ~D[2027-03-30]})

      assert updated.end_date == ~D[2027-03-30]
    end
  end

  describe "for_window/3" do
    test "returns trips overlapping the window with days preloaded" do
      profile = insert(:profile)

      period =
        insert(:travel_period,
          profile: profile,
          start_date: ~D[2027-03-14],
          end_date: ~D[2027-03-28]
        )

      insert(:travel_period_day, travel_period: period, day_of_week: 3)

      assert [found] = Travel.for_window(profile.id, ~D[2027-03-01], ~D[2027-03-31])
      assert [_day] = found.days
    end
  end

  describe "set_day/3" do
    test "replaces the hours for a weekday already set" do
      profile = insert(:profile)
      period = insert(:travel_period, profile: profile)

      assert {:ok, _first} =
               Travel.set_day(profile, period, %{
                 day_of_week: 3,
                 is_available: true,
                 start_time: ~T[10:00:00],
                 end_time: ~T[16:00:00]
               })

      assert {:ok, replaced} =
               Travel.set_day(profile, period, %{
                 day_of_week: 3,
                 is_available: true,
                 start_time: ~T[11:00:00],
                 end_time: ~T[15:00:00]
               })

      assert replaced.start_time == ~T[11:00:00]
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/tymeslot/availability/travel_test.exs`
Expected: FAIL — `Tymeslot.Availability.Travel is not available`

- [ ] **Step 3: Write the context**

Create `lib/tymeslot/availability/travel.ex`:

```elixir
defmodule Tymeslot.Availability.Travel do
  @moduledoc """
  Travel periods: the date ranges during which a profile's timezone and hours
  differ. The sibling of `Tymeslot.Availability.Schedules`.

  `for_window/3` is the single trip resolver, called by both
  `Tymeslot.Bookings.Policy.scheduling_config/2` (the submit path) and the
  booking page's display path. Having one resolver is what makes the two paths
  structurally unable to disagree about which trips apply — the same reason
  `Policy.slot_interval_minutes/1` exists.

  Every write takes the profile struct rather than a profile id, because the
  availability cache is keyed by user and the struct already carries
  `user_id`. Deriving it from the id would mean an extra query, or a query
  module reaching into another domain's schema.

  Non-overlap is enforced here rather than by a database exclusion constraint:
  the rigorous form needs the `btree_gist` extension, which some managed
  Postgres will not grant a non-superuser, and Core ships to self-hosters. The
  race window is one person editing their own trips.
  """

  alias Tymeslot.Availability.TravelPeriodDaySchema
  alias Tymeslot.Availability.TravelPeriodQueries
  alias Tymeslot.Availability.TravelPeriodSchema
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Profiles.ProfileSchema

  @doc """
  Trips overlapping an inclusive date window, `:days` preloaded.
  """
  @spec for_window(integer(), Date.t(), Date.t()) :: [TravelPeriodSchema.t()]
  defdelegate for_window(profile_id, start_date, end_date),
    to: TravelPeriodQueries,
    as: :list_overlapping

  @doc """
  Every trip a profile owns, earliest first.
  """
  @spec list_for_profile(integer()) :: [TravelPeriodSchema.t()]
  defdelegate list_for_profile(profile_id),
    to: TravelPeriodQueries,
    as: :list_by_profile

  @doc """
  Creates a trip for a profile, refusing one that overlaps an existing trip.
  """
  @spec create_period(ProfileSchema.t(), map()) ::
          {:ok, TravelPeriodSchema.t()} | {:error, Ecto.Changeset.t()}
  def create_period(%ProfileSchema{} = profile, attrs) do
    %TravelPeriodSchema{}
    |> TravelPeriodSchema.changeset(Map.put(normalise(attrs), :profile_id, profile.id))
    |> reject_overlap(profile.id, nil)
    |> TravelPeriodQueries.insert_period()
    |> invalidate(profile)
  end

  @doc """
  Updates a trip, refusing a change that would overlap another trip.
  """
  @spec update_period(ProfileSchema.t(), TravelPeriodSchema.t(), map()) ::
          {:ok, TravelPeriodSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_period(%ProfileSchema{} = profile, %TravelPeriodSchema{} = period, attrs) do
    period
    |> TravelPeriodSchema.changeset(normalise(attrs))
    |> reject_overlap(profile.id, period.id)
    |> TravelPeriodQueries.update_period()
    |> invalidate(profile)
  end

  @doc """
  Deletes a trip and its days.
  """
  @spec delete_period(ProfileSchema.t(), TravelPeriodSchema.t()) ::
          {:ok, TravelPeriodSchema.t()} | {:error, Ecto.Changeset.t()}
  def delete_period(%ProfileSchema{} = profile, %TravelPeriodSchema{} = period) do
    period
    |> TravelPeriodQueries.delete_period()
    |> invalidate(profile)
  end

  @doc """
  Sets one weekday's hours within a trip, replacing any already stored.
  """
  @spec set_day(ProfileSchema.t(), TravelPeriodSchema.t(), map()) ::
          {:ok, TravelPeriodDaySchema.t()} | {:error, Ecto.Changeset.t()}
  def set_day(%ProfileSchema{} = profile, %TravelPeriodSchema{} = period, attrs) do
    attrs
    |> normalise()
    |> Map.put(:travel_period_id, period.id)
    |> TravelPeriodQueries.upsert_day()
    |> invalidate(profile)
  end

  # Accepts either string or atom keys, so a LiveView form's params and a
  # direct caller's map both work without each call site converting.
  defp normalise(attrs) do
    Map.new(attrs, fn
      {key, value} when is_binary(key) -> {String.to_existing_atom(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp reject_overlap(%Ecto.Changeset{valid?: false} = changeset, _profile_id, _exclude_id),
    do: changeset

  defp reject_overlap(changeset, profile_id, exclude_id) do
    start_date = Ecto.Changeset.get_field(changeset, :start_date)
    end_date = Ecto.Changeset.get_field(changeset, :end_date)

    case TravelPeriodQueries.overlapping(profile_id, start_date, end_date, exclude_id) do
      [] -> changeset
      [_ | _] -> Ecto.Changeset.add_error(changeset, :start_date, "overlaps an existing trip")
    end
  end

  # Availability for every one of this user's meeting types can change when a
  # trip does, so the whole user's cache goes rather than any narrower key.
  defp invalidate({:ok, _record} = result, %ProfileSchema{user_id: user_id}) do
    AvailabilityCache.invalidate_for_user(user_id)
    result
  end

  defp invalidate({:error, _changeset} = result, _profile), do: result
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/tymeslot/availability/travel_test.exs`
Expected: PASS, 7 tests

- [ ] **Step 5: Verify Stage 1 as a whole**

Run: `mix test test/tymeslot/availability/ && mix credo --strict lib/tymeslot/availability/ && mix format --check-formatted`
Expected: all pass. The engine is untouched, so every pre-existing availability test must still pass.

- [ ] **Step 6: Commit**

```bash
git add lib/tymeslot/availability/travel.ex test/tymeslot/availability/travel_test.exs
git commit -m "feat(availability): add travel period context with overlap validation"
```

---

# Stage 2 — The availability engine

Independently verifiable and the heart of the feature. Gate: the agreement test in Task 7 must pass, proving the booking page and the booking-time re-check resolve trips identically.

### Task 4: `OwnerFrame`

**Files:**
- Create: `lib/tymeslot/availability/owner_frame.ex`
- Test: `test/tymeslot/availability/owner_frame_test.exs`

**Interfaces:**
- Consumes: `Travel.for_window/3` from Task 3
- Produces: `OwnerFrame.for_date(Date.t(), String.t(), map()) :: %{timezone: String.t(), day: map() | nil, source: :travel | :schedule}`

The `day` map, when present, has keys `:is_available`, `:day_of_week`, `:start_time`, `:end_time`, `:breaks` — the same shape as `BusinessHours.day_availability()`. `day` is `nil` when no trip covers the date, which is how `BusinessHours` knows to fall through to its own weekly lookup.

- [ ] **Step 1: Write the failing test**

Create `test/tymeslot/availability/owner_frame_test.exs`:

```elixir
defmodule Tymeslot.Availability.OwnerFrameTest do
  use Tymeslot.DataCase, async: true

  @moduletag :availability
  @moduletag :unit

  import Tymeslot.Factory

  alias Tymeslot.Availability.OwnerFrame

  @home "America/New_York"

  defp trip(start_date, end_date, timezone, days) do
    %{
      start_date: start_date,
      end_date: end_date,
      timezone: timezone,
      days: days
    }
  end

  defp day(day_of_week, start_time, end_time) do
    %{
      day_of_week: day_of_week,
      is_available: true,
      start_time: start_time,
      end_time: end_time
    }
  end

  describe "for_date/3 with no trips" do
    test "returns the home zone and no day when the config carries an empty list" do
      frame = OwnerFrame.for_date(~D[2027-03-17], @home, %{travel_periods: []})

      assert frame == %{timezone: @home, day: nil, source: :schedule}
    end

    test "returns the home zone when the config carries no trip key at all" do
      frame = OwnerFrame.for_date(~D[2027-03-17], @home, %{})

      assert frame.timezone == @home
      assert frame.day == nil
      assert frame.source == :schedule
    end

    test "returns the home zone for a date outside every trip" do
      periods = [trip(~D[2027-03-14], ~D[2027-03-28], "Europe/Berlin", [day(3, ~T[10:00:00], ~T[16:00:00])])]

      frame = OwnerFrame.for_date(~D[2027-04-07], @home, %{travel_periods: periods})

      assert frame.timezone == @home
      assert frame.source == :schedule
    end
  end

  describe "for_date/3 inside a trip" do
    test "returns the trip zone and that weekday's hours" do
      periods = [trip(~D[2027-03-14], ~D[2027-03-28], "Europe/Berlin", [day(3, ~T[10:00:00], ~T[16:00:00])])]

      # 2027-03-17 is a Wednesday.
      frame = OwnerFrame.for_date(~D[2027-03-17], @home, %{travel_periods: periods})

      assert frame.timezone == "Europe/Berlin"
      assert frame.source == :travel
      assert frame.day.is_available
      assert frame.day.start_time == ~T[10:00:00]
      assert frame.day.end_time == ~T[16:00:00]
      assert frame.day.day_of_week == 3
      assert frame.day.breaks == []
    end

    test "reports a weekday the trip does not define as unavailable" do
      periods = [trip(~D[2027-03-14], ~D[2027-03-28], "Europe/Berlin", [day(3, ~T[10:00:00], ~T[16:00:00])])]

      # 2027-03-18 is a Thursday, which this trip leaves undefined.
      frame = OwnerFrame.for_date(~D[2027-03-18], @home, %{travel_periods: periods})

      assert frame.timezone == "Europe/Berlin"
      refute frame.day.is_available
      assert frame.day.start_time == nil
    end

    test "includes both inclusive boundary dates" do
      periods = [trip(~D[2027-03-14], ~D[2027-03-28], "Europe/Berlin", [])]
      config = %{travel_periods: periods}

      assert OwnerFrame.for_date(~D[2027-03-14], @home, config).source == :travel
      assert OwnerFrame.for_date(~D[2027-03-28], @home, config).source == :travel
      assert OwnerFrame.for_date(~D[2027-03-13], @home, config).source == :schedule
      assert OwnerFrame.for_date(~D[2027-03-29], @home, config).source == :schedule
    end

    test "fails closed when a trip's days did not load" do
      periods = [
        %{
          start_date: ~D[2027-03-14],
          end_date: ~D[2027-03-28],
          timezone: "Europe/Berlin",
          days: %Ecto.Association.NotLoaded{}
        }
      ]

      frame = OwnerFrame.for_date(~D[2027-03-17], @home, %{travel_periods: periods})

      # Offering nothing is the safe direction: the alternative would be home
      # hours applied in a foreign zone.
      assert frame.timezone == "Europe/Berlin"
      refute frame.day.is_available
    end
  end

  describe "for_date/3 falling back to a query" do
    test "reads trips from the database when the config carries only a profile id" do
      profile = insert(:profile)

      period =
        insert(:travel_period,
          profile: profile,
          start_date: ~D[2027-03-14],
          end_date: ~D[2027-03-28],
          timezone: "Europe/Berlin"
        )

      insert(:travel_period_day,
        travel_period: period,
        day_of_week: 3,
        is_available: true,
        start_time: ~T[10:00:00],
        end_time: ~T[16:00:00]
      )

      frame = OwnerFrame.for_date(~D[2027-03-17], @home, %{profile_id: profile.id})

      assert frame.timezone == "Europe/Berlin"
      assert frame.day.start_time == ~T[10:00:00]
    end

    test "prefers a prefetched list over querying" do
      profile = insert(:profile)

      insert(:travel_period,
        profile: profile,
        start_date: ~D[2027-03-14],
        end_date: ~D[2027-03-28],
        timezone: "Europe/Berlin"
      )

      # An explicit empty list means "no trips in this window", and must not be
      # second-guessed by a query.
      frame =
        OwnerFrame.for_date(~D[2027-03-17], @home, %{
          profile_id: profile.id,
          travel_periods: []
        })

      assert frame.timezone == @home
      assert frame.source == :schedule
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/tymeslot/availability/owner_frame_test.exs`
Expected: FAIL — `Tymeslot.Availability.OwnerFrame is not available`

- [ ] **Step 3: Write `OwnerFrame`**

Create `lib/tymeslot/availability/owner_frame.ex`:

```elixir
defmodule Tymeslot.Availability.OwnerFrame do
  @moduledoc """
  The owner's timezone and hours in effect on a single date.

  One function answers "which clock is the owner on, and which hours do they
  offer, on date D". `BusinessHours.get_business_hours_in_timezone/5` calls it,
  and because every availability path — the booking page's slot list, the month
  grid, the range availability map and the booking-time re-check in
  `Tymeslot.Bookings.ScheduleCheck` — resolves a day's window through that one
  function, all of them inherit travel periods without each having to remember
  to. That is deliberate: the offered slots and the re-check that validates a
  submission must never disagree.

  Named for the "owner frame" vocabulary `Tymeslot.Availability.TimeSlots`
  already uses for the owner-side date a window was read for.

  `day` is `nil` when no trip covers the date. The `nil` is what lets
  `BusinessHours` keep its own private weekly lookup as the non-trip path,
  rather than this module needing a `schedule_id` and duplicating that logic.

  Trips are read from `config[:travel_periods]` when a caller prefetched them,
  and otherwise queried per date using `config[:profile_id]` — the same
  prefetch-or-query fallback `BusinessHours.lookup_override/3` and
  `lookup_day_availability/3` already use, so a caller that cannot prefetch
  still gets correct answers.
  """

  alias Tymeslot.Availability.Travel

  @type t :: %{
          timezone: String.t(),
          day: map() | nil,
          source: :travel | :schedule
        }

  @doc """
  The zone and hours in effect on `date`.

  `owner_timezone` is the owner's *home* zone — the fallback used whenever no
  trip covers the date. It is not necessarily the effective zone, which is this
  function's whole purpose.
  """
  @spec for_date(Date.t(), String.t(), map()) :: t()
  def for_date(date, owner_timezone, config) do
    case covering_period(date, config) do
      nil ->
        %{timezone: owner_timezone, day: nil, source: :schedule}

      period ->
        %{timezone: period.timezone, day: day_for(period, date), source: :travel}
    end
  end

  # An explicit list wins, including an empty one: a caller that prefetched a
  # window has already established there are no trips in it, and re-querying
  # would undo the prefetch's whole purpose.
  defp covering_period(date, %{travel_periods: periods}) when is_list(periods) do
    Enum.find(periods, &covers?(&1, date))
  end

  defp covering_period(date, %{profile_id: profile_id}) when is_integer(profile_id) do
    profile_id
    |> Travel.for_window(date, date)
    |> Enum.find(&covers?(&1, date))
  end

  defp covering_period(_date, _config), do: nil

  defp covers?(period, date) do
    Date.compare(date, period.start_date) != :lt and
      Date.compare(date, period.end_date) != :gt
  end

  defp day_for(period, date) do
    day_of_week = Date.day_of_week(date)

    # An unloaded association reads as no hours, so a trip whose days failed to
    # preload offers nothing rather than falling back to home hours interpreted
    # in a foreign zone — which would offer the wrong times, not merely fewer.
    days = if is_list(period.days), do: period.days, else: []

    case Enum.find(days, &(&1.day_of_week == day_of_week)) do
      nil ->
        unavailable(day_of_week)

      day ->
        %{
          is_available: day.is_available,
          day_of_week: day_of_week,
          start_time: day.start_time,
          end_time: day.end_time,
          breaks: []
        }
    end
  end

  defp unavailable(day_of_week) do
    %{
      is_available: false,
      day_of_week: day_of_week,
      start_time: nil,
      end_time: nil,
      breaks: []
    }
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/tymeslot/availability/owner_frame_test.exs`
Expected: PASS, 10 tests

- [ ] **Step 5: Commit**

```bash
git add lib/tymeslot/availability/owner_frame.ex \
        test/tymeslot/availability/owner_frame_test.exs
git commit -m "feat(availability): resolve the owner's zone and hours per date"
```

---

### Task 5: Wire `OwnerFrame` into `BusinessHours`

**Files:**
- Modify: `lib/tymeslot/availability/business_hours.ex:60-100`
- Test: `test/tymeslot/availability/business_hours_travel_test.exs`

**Interfaces:**
- Consumes: `OwnerFrame.for_date/3` from Task 4
- Produces: no signature changes. `BusinessHours.get_business_hours_in_timezone/5` keeps its arity and argument order; `owner_timezone` now means the home-zone fallback.

- [ ] **Step 1: Write the failing test**

Create `test/tymeslot/availability/business_hours_travel_test.exs`:

```elixir
defmodule Tymeslot.Availability.BusinessHoursTravelTest do
  use Tymeslot.DataCase, async: true

  @moduletag :availability
  @moduletag :unit

  alias Tymeslot.Availability.BusinessHours

  @home "America/New_York"

  # 2027-03-17 is a Wednesday.
  @wednesday ~D[2027-03-17]

  defp config(overrides \\ %{}) do
    Map.merge(
      %{
        weekly_schedule: [
          %{day_of_week: 3, is_available: true, start_time: ~T[09:00:00], end_time: ~T[17:00:00], breaks: []}
        ],
        overrides: [],
        travel_periods: []
      },
      overrides
    )
  end

  defp berlin_trip do
    [
      %{
        start_date: ~D[2027-03-14],
        end_date: ~D[2027-03-28],
        timezone: "Europe/Berlin",
        days: [
          %{day_of_week: 3, is_available: true, start_time: ~T[10:00:00], end_time: ~T[16:00:00]}
        ]
      }
    ]
  end

  describe "get_business_hours_in_timezone/5" do
    test "uses the home zone and schedule hours with no trips" do
      assert {:ok, hours} =
               BusinessHours.get_business_hours_in_timezone(@wednesday, 1, @home, @home, config())

      assert DateTime.to_time(hours.start_datetime) == ~T[09:00:00]
      assert hours.start_datetime.time_zone == @home
    end

    test "uses the trip zone and trip hours inside a trip" do
      config = config(%{travel_periods: berlin_trip()})

      assert {:ok, hours} =
               BusinessHours.get_business_hours_in_timezone(
                 @wednesday,
                 1,
                 @home,
                 "Europe/Berlin",
                 config
               )

      # 10:00 read in Berlin, rendered in Berlin.
      assert DateTime.to_time(hours.start_datetime) == ~T[10:00:00]
      assert DateTime.to_time(hours.end_datetime) == ~T[16:00:00]
    end

    test "converts trip hours into the booker's zone" do
      config = config(%{travel_periods: berlin_trip()})

      assert {:ok, hours} =
               BusinessHours.get_business_hours_in_timezone(@wednesday, 1, @home, @home, config)

      expected =
        @wednesday
        |> DateTime.new!(~T[10:00:00], "Europe/Berlin")
        |> DateTime.shift_zone!(@home)
        |> DateTime.to_time()

      assert DateTime.to_time(hours.start_datetime) == expected
    end

    test "leaves a weekday the trip does not define unbookable" do
      config = config(%{travel_periods: berlin_trip()})
      # 2027-03-18 is a Thursday, undefined by the trip but available on the schedule.
      thursday = ~D[2027-03-18]

      schedule_config =
        Map.put(config, :weekly_schedule, [
          %{day_of_week: 4, is_available: true, start_time: ~T[09:00:00], end_time: ~T[17:00:00], breaks: []}
        ])

      assert {:ok, hours} =
               BusinessHours.get_business_hours_in_timezone(
                 thursday,
                 1,
                 @home,
                 @home,
                 schedule_config
               )

      assert hours.start_datetime == nil
    end

    test "an unavailable override still wins inside a trip" do
      config =
        config(%{
          travel_periods: berlin_trip(),
          overrides: [%{date: @wednesday, schedule_id: 1, override_type: "unavailable"}]
        })

      assert {:ok, hours} =
               BusinessHours.get_business_hours_in_timezone(@wednesday, 1, @home, @home, config)

      assert hours.start_datetime == nil
    end

    test "a custom-hours override inside a trip is read in the trip zone" do
      config =
        config(%{
          travel_periods: berlin_trip(),
          overrides: [
            %{
              date: @wednesday,
              schedule_id: 1,
              override_type: "custom_hours",
              start_time: ~T[13:00:00],
              end_time: ~T[15:00:00]
            }
          ]
        })

      assert {:ok, hours} =
               BusinessHours.get_business_hours_in_timezone(
                 @wednesday,
                 1,
                 @home,
                 "Europe/Berlin",
                 config
               )

      assert DateTime.to_time(hours.start_datetime) == ~T[13:00:00]
    end

    test "a trip applies even when no schedule resolves" do
      config = config(%{travel_periods: berlin_trip()})

      assert {:ok, hours} =
               BusinessHours.get_business_hours_in_timezone(
                 @wednesday,
                 nil,
                 @home,
                 "Europe/Berlin",
                 config
               )

      assert DateTime.to_time(hours.start_datetime) == ~T[10:00:00]
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/tymeslot/availability/business_hours_travel_test.exs`
Expected: FAIL — the trip tests get schedule hours (09:00) instead of trip hours (10:00), and the `nil` schedule test gets the fallback window.

- [ ] **Step 3: Add the alias**

In `lib/tymeslot/availability/business_hours.ex`, add to the alias block in alphabetical position:

```elixir
  alias Tymeslot.Availability.OwnerFrame
```

- [ ] **Step 4: Replace both clauses of `get_business_hours_in_timezone/5`**

Replace the existing two clauses (currently `business_hours.ex:60-100`) with:

```elixir
  def get_business_hours_in_timezone(date, nil, owner_timezone, user_timezone, config) do
    case OwnerFrame.for_date(date, owner_timezone, config) do
      %{source: :travel, timezone: timezone, day: day} ->
        business_hours_from_day(date, day, timezone, user_timezone)

      %{source: :schedule} ->
        get_business_hours_in_timezone_fallback(date, owner_timezone, user_timezone)
    end
  end

  def get_business_hours_in_timezone(date, schedule_id, owner_timezone, user_timezone, config) do
    # `owner_timezone` is the home-zone fallback, not necessarily the effective
    # zone: a travel period covering `date` supplies its own zone and hours.
    frame = OwnerFrame.for_date(date, owner_timezone, config)
    override = lookup_override(date, schedule_id, config)

    case override do
      %{override_type: "unavailable"} ->
        {:ok, %{start_datetime: nil, end_datetime: nil, selected_date: date}}

      %{override_type: type, start_time: start_time, end_time: end_time}
      when type in ["custom_hours", "available"] and start_time != nil and end_time != nil ->
        convert_business_hours_to_user_timezone(
          date,
          start_time,
          end_time,
          frame.timezone,
          user_timezone
        )

      _no_override ->
        # A trip supplies the day; otherwise fall through to the schedule's own
        # weekly lookup, which is why `frame.day` is nil outside a trip.
        day_availability =
          frame.day || lookup_day_availability(Date.day_of_week(date), schedule_id, config)

        business_hours_from_day(date, day_availability, frame.timezone, user_timezone)
    end
  end

  defp business_hours_from_day(date, day_availability, timezone, user_timezone) do
    case day_availability do
      %{is_available: true, start_time: start_time, end_time: end_time}
      when start_time != nil and end_time != nil ->
        convert_business_hours_to_user_timezone(
          date,
          start_time,
          end_time,
          timezone,
          user_timezone
        )

      _other ->
        {:ok, %{start_datetime: nil, end_datetime: nil, selected_date: date}}
    end
  end
```

- [ ] **Step 5: Run the new test and the whole availability suite**

Run: `mix test test/tymeslot/availability/business_hours_travel_test.exs && mix test test/tymeslot/availability/`
Expected: the new file PASSES (7 tests), and every pre-existing availability test still passes. With no trips in config, `frame.day` is `nil` and `frame.timezone` is `owner_timezone`, so behaviour is unchanged.

- [ ] **Step 6: Commit**

```bash
git add lib/tymeslot/availability/business_hours.ex \
        test/tymeslot/availability/business_hours_travel_test.exs
git commit -m "feat(availability): resolve business hours through the owner frame"
```

---

### Task 6: Prefetch trips for a window

**Files:**
- Modify: `lib/tymeslot/availability/calculate.ex` — the `availability_config` typedoc, and add `prefetch_travel_periods/4` beside `prefetch_schedule_data/4`
- Test: `test/tymeslot/availability/calculate_travel_prefetch_test.exs`

**Interfaces:**
- Consumes: `Travel.for_window/3` from Task 3
- Produces: `Calculate.prefetch_travel_periods(config :: map(), profile_id :: integer() | nil, Date.t(), Date.t()) :: map()` — puts `:travel_periods`, leaving an existing key untouched

- [ ] **Step 1: Write the failing test**

Create `test/tymeslot/availability/calculate_travel_prefetch_test.exs`:

```elixir
defmodule Tymeslot.Availability.CalculateTravelPrefetchTest do
  use Tymeslot.DataCase, async: true

  @moduletag :availability
  @moduletag :unit

  import Tymeslot.Factory

  alias Tymeslot.Availability.Calculate

  describe "prefetch_travel_periods/4" do
    test "loads the window's trips with days preloaded" do
      profile = insert(:profile)

      period =
        insert(:travel_period,
          profile: profile,
          start_date: ~D[2027-03-14],
          end_date: ~D[2027-03-28]
        )

      insert(:travel_period_day, travel_period: period, day_of_week: 3)

      config = Calculate.prefetch_travel_periods(%{}, profile.id, ~D[2027-03-01], ~D[2027-03-31])

      assert [loaded] = config.travel_periods
      assert loaded.id == period.id
      assert [_day] = loaded.days
    end

    test "passes the config through untouched when there is no profile" do
      config = Calculate.prefetch_travel_periods(%{}, nil, ~D[2027-03-01], ~D[2027-03-31])

      refute Map.has_key?(config, :travel_periods)
    end

    test "leaves an already-populated key alone" do
      profile = insert(:profile)

      insert(:travel_period,
        profile: profile,
        start_date: ~D[2027-03-14],
        end_date: ~D[2027-03-28]
      )

      config =
        Calculate.prefetch_travel_periods(
          %{travel_periods: []},
          profile.id,
          ~D[2027-03-01],
          ~D[2027-03-31]
        )

      assert config.travel_periods == []
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/tymeslot/availability/calculate_travel_prefetch_test.exs`
Expected: FAIL — `function Calculate.prefetch_travel_periods/4 is undefined`

- [ ] **Step 3: Extend the config typedoc**

In `lib/tymeslot/availability/calculate.ex`, add these two entries to the `availability_config` type, and add `alias Tymeslot.Availability.Travel` to the alias block in alphabetical position:

```elixir
          optional(:travel_periods) => list(term()),
          optional(:profile_id) => pos_integer(),
```

Then amend the `:owner_timezone` line's meaning by adding this note directly above the type:

```elixir
  # `:owner_timezone` is the owner's *home* zone. The zone actually in effect on
  # a given date comes from `Tymeslot.Availability.OwnerFrame`, because a travel
  # period covering that date supplies its own. `:travel_periods` carries a
  # prefetched window; `:profile_id` lets `OwnerFrame` query per date when a
  # caller could not prefetch.
```

- [ ] **Step 4: Add `prefetch_travel_periods/4`**

In `lib/tymeslot/availability/calculate.ex`, directly after `prefetch_schedule_data/4`:

```elixir
  @doc """
  Loads the travel periods overlapping `start_date..end_date` into `config`.

  A sibling of `prefetch_schedule_data/4` rather than part of it, because that
  function is keyed by `schedule_id` and returns early when there is none,
  while travel periods hang off the profile and apply to every meeting type.
  Folding them in would silently skip the trip load for any caller without a
  schedule.

  An existing `:travel_periods` key wins, so a caller that already has the
  window passes it through untouched.
  """
  @spec prefetch_travel_periods(availability_config(), integer() | nil, Date.t(), Date.t()) ::
          availability_config()
  def prefetch_travel_periods(config, nil, _start_date, _end_date), do: config

  def prefetch_travel_periods(config, profile_id, start_date, end_date) do
    Map.put_new_lazy(config, :travel_periods, fn ->
      Travel.for_window(profile_id, start_date, end_date)
    end)
  end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test test/tymeslot/availability/calculate_travel_prefetch_test.exs`
Expected: PASS, 3 tests

- [ ] **Step 6: Commit**

```bash
git add lib/tymeslot/availability/calculate.ex \
        test/tymeslot/availability/calculate_travel_prefetch_test.exs
git commit -m "feat(availability): prefetch travel periods for an availability window"
```

---

### Task 7: Feed trips to both config builders — **the stage gate**

**Files:**
- Modify: `lib/tymeslot/profiles.ex:275-296` — add `profile_id` to the settings map
- Modify: `lib/tymeslot/bookings/policy.ex:53-61` — put `:profile_id` into the config
- Modify: `lib/tymeslot_web/live/scheduling/availability_helpers.ex` — add `put_travel_periods/4` and call it at both `schedule_config/4` call sites
- Test: `test/tymeslot/availability/travel_path_agreement_test.exs`

**Interfaces:**
- Consumes: `Calculate.prefetch_travel_periods/4` (Task 6), `Travel.for_window/3` (Task 3), `OwnerFrame` (Task 4) via `BusinessHours` (Task 5)
- Produces:
  - `Profiles.get_profile_settings/1` gains `profile_id: integer() | nil`
  - `Policy.scheduling_config/2` result gains `:profile_id`
  - `AvailabilityHelpers.put_travel_periods(config :: map(), organizer_profile :: map() | nil, Date.t(), Date.t()) :: map()`

- [ ] **Step 1: Write the failing test**

Create `test/tymeslot/availability/travel_path_agreement_test.exs`:

```elixir
defmodule Tymeslot.Availability.TravelPathAgreementTest do
  use Tymeslot.DataCase, async: true

  @moduletag :availability
  @moduletag :integration

  import Tymeslot.Factory

  alias Tymeslot.Availability.Calculate
  alias Tymeslot.Availability.Travel
  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Bookings.ScheduleCheck
  alias Tymeslot.Utils.DateTimeUtils
  alias TymeslotWeb.Live.Scheduling.AvailabilityHelpers

  @home "America/New_York"
  @away "Europe/Berlin"

  # A Wednesday at least `days_ahead` out, so the test never rots as the clock
  # moves and never depends on a hard-coded year.
  defp wednesday_at_least(days_ahead) do
    base = Date.add(Date.utc_today(), days_ahead)
    Date.add(base, rem(10 - Date.day_of_week(base), 7))
  end

  setup do
    user = insert(:user)
    profile = insert(:profile, user: user, timezone: @home)

    schedule =
      insert(:availability_schedule,
        profile: profile,
        is_default: true,
        buffer_minutes: 0,
        min_advance_hours: 0,
        advance_booking_days: 365
      )

    for day_of_week <- 1..5 do
      insert(:weekly_availability,
        schedule: schedule,
        day_of_week: day_of_week,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )
    end

    meeting_type =
      insert(:meeting_type,
        user: user,
        duration_minutes: 30,
        availability_schedule_id: schedule.id
      )

    in_trip = wednesday_at_least(60)
    after_trip = Date.add(in_trip, 14)

    {:ok, trip} =
      Travel.create_period(profile, %{
        label: "Berlin",
        start_date: Date.add(in_trip, -2),
        end_date: Date.add(in_trip, 2),
        timezone: @away
      })

    {:ok, _day} =
      Travel.set_day(profile, trip, %{
        day_of_week: 3,
        is_available: true,
        start_time: ~T[10:00:00],
        end_time: ~T[16:00:00]
      })

    %{
      user: user,
      profile: profile,
      schedule: schedule,
      meeting_type: meeting_type,
      in_trip: in_trip,
      after_trip: after_trip
    }
  end

  describe "the submit path" do
    test "carries the profile id so trips resolve", ctx do
      config = Policy.scheduling_config(ctx.user.id, ctx.meeting_type)

      assert config.profile_id == ctx.profile.id
      assert config.owner_timezone == @home
    end

    test "offers trip hours for a date inside the trip", ctx do
      config = Policy.scheduling_config(ctx.user.id, ctx.meeting_type)

      {:ok, slots} =
        Calculate.available_slots(ctx.in_trip, 30, @home, config.owner_timezone, [], config)

      expected =
        ctx.in_trip
        |> DateTime.new!(~T[10:00:00], @away)
        |> DateTime.shift_zone!(@home)
        |> DateTime.to_time()

      refute slots == []
      assert {:ok, first} = DateTimeUtils.parse_time_string(List.first(slots))
      assert first == expected
    end

    test "offers home hours for a date after the trip", ctx do
      config = Policy.scheduling_config(ctx.user.id, ctx.meeting_type)

      {:ok, slots} =
        Calculate.available_slots(ctx.after_trip, 30, @home, config.owner_timezone, [], config)

      refute slots == []
      assert {:ok, first} = DateTimeUtils.parse_time_string(List.first(slots))
      assert first == ~T[09:00:00]
    end
  end

  describe "agreement between the display path and the submit path" do
    test "every slot offered inside a trip is accepted by the re-check", ctx do
      config = Policy.scheduling_config(ctx.user.id, ctx.meeting_type)

      {:ok, slots} =
        Calculate.available_slots(ctx.in_trip, 30, @home, config.owner_timezone, [], config)

      refute slots == []

      Enum.each(slots, fn slot ->
        {:ok, time} = DateTimeUtils.parse_time_string(slot)
        {:ok, start_dt} = DateTime.new(ctx.in_trip, time, @home)

        assert :ok =
                 ScheduleCheck.validate_slot_on_schedule(
                   ctx.in_trip,
                   start_dt,
                   30,
                   @home,
                   config,
                   ctx.user.id
                 )
      end)
    end

    test "every slot offered after a trip is accepted by the re-check", ctx do
      config = Policy.scheduling_config(ctx.user.id, ctx.meeting_type)

      {:ok, slots} =
        Calculate.available_slots(ctx.after_trip, 30, @home, config.owner_timezone, [], config)

      Enum.each(slots, fn slot ->
        {:ok, time} = DateTimeUtils.parse_time_string(slot)
        {:ok, start_dt} = DateTime.new(ctx.after_trip, time, @home)

        assert :ok =
                 ScheduleCheck.validate_slot_on_schedule(
                   ctx.after_trip,
                   start_dt,
                   30,
                   @home,
                   config,
                   ctx.user.id
                 )
      end)
    end

    test "a home-hours slot inside the trip window is refused", ctx do
      config = Policy.scheduling_config(ctx.user.id, ctx.meeting_type)

      # 09:00 New York is 15:00 Berlin, inside 10:00-16:00, so pick a time that
      # is bookable at home but outside the trip's hours: 11:00 New York is
      # 17:00 Berlin.
      {:ok, start_dt} = DateTime.new(ctx.in_trip, ~T[11:00:00], @home)

      assert {:error, :slot_not_offered} =
               ScheduleCheck.validate_slot_on_schedule(
                 ctx.in_trip,
                 start_dt,
                 30,
                 @home,
                 config,
                 ctx.user.id
               )
    end

    test "the display path resolves the same trips as the submit path", ctx do
      display_config =
        ctx.schedule
        |> AvailabilityHelpers.schedule_config(ctx.meeting_type, nil, 30)
        |> AvailabilityHelpers.put_travel_periods(ctx.profile, ctx.in_trip, ctx.in_trip)

      expected_ids =
        ctx.profile.id
        |> Travel.for_window(ctx.in_trip, ctx.in_trip)
        |> Enum.map(& &1.id)

      assert Enum.map(display_config.travel_periods, & &1.id) == expected_ids
      refute expected_ids == []
    end

    test "the display path carries no trips for a post-return window", ctx do
      display_config =
        ctx.schedule
        |> AvailabilityHelpers.schedule_config(ctx.meeting_type, nil, 30)
        |> AvailabilityHelpers.put_travel_periods(ctx.profile, ctx.after_trip, ctx.after_trip)

      assert display_config.travel_periods == []
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/tymeslot/availability/travel_path_agreement_test.exs`
Expected: FAIL — `config.profile_id` is missing and `AvailabilityHelpers.put_travel_periods/4` is undefined.

- [ ] **Step 3: Add `profile_id` to the profile settings map**

In `lib/tymeslot/profiles.ex`, in `get_profile_settings/1`, add `profile_id` to both branches:

```elixir
      {:error, :not_found} ->
        %{
          profile_id: nil,
          timezone: get_default_timezone(),
          max_bookings_per_day: nil,
          max_bookings_per_week: nil,
          max_bookings_per_month: nil
        }

      {:ok, profile} ->
        %{
          # Carried so callers that hold only a user id can resolve travel
          # periods, which hang off the profile.
          profile_id: profile.id,
          # A profile's timezone column is nullable, so fall back here as
          # `get_user_timezone/1` does — the declared `timezone` type is
          # non-nil, and every caller reads a usable zone rather than each
          # remembering the fallback.
          timezone: profile.timezone || get_default_timezone(),
          max_bookings_per_day: profile.max_bookings_per_day,
          max_bookings_per_week: profile.max_bookings_per_week,
          max_bookings_per_month: profile.max_bookings_per_month
        }
```

- [ ] **Step 4: Put `:profile_id` into the submit path's config**

In `lib/tymeslot/bookings/policy.ex`, extend both clauses of `scheduling_config/2`:

```elixir
  def scheduling_config(nil, _meeting_type) do
    nil
    |> policy_values()
    |> Map.put(:owner_timezone, Profiles.get_default_timezone())
    |> Map.put(:profile_id, nil)
    |> Map.put(:slot_interval_minutes, nil)
  end

  def scheduling_config(organizer_user_id, meeting_type) do
    settings = Profiles.get_profile_settings(organizer_user_id)

    organizer_user_id
    |> resolve_schedule(meeting_type)
    |> policy_values()
    |> Map.put(:owner_timezone, settings.timezone)
    # No date is in scope here, so trips are not prefetched: `OwnerFrame` reads
    # them per date from this id, the same prefetch-or-query fallback
    # `BusinessHours` already uses for overrides and weekly days.
    |> Map.put(:profile_id, settings.profile_id)
    |> Map.put(:slot_interval_minutes, slot_interval_minutes(meeting_type))
  end
```

- [ ] **Step 5: Add `put_travel_periods/4` to the display path**

In `lib/tymeslot_web/live/scheduling/availability_helpers.ex`, add `alias Tymeslot.Availability.Travel` in alphabetical position, then add this function directly after `schedule_config/4`:

```elixir
  @doc """
  Loads the travel periods overlapping an inclusive date window into `config`.

  The display path's counterpart to the `:profile_id` that
  `Tymeslot.Bookings.Policy.scheduling_config/2` carries. Both end up going
  through `Tymeslot.Availability.OwnerFrame`, which is what stops the offered
  slots and the booking-time re-check from disagreeing about which trips apply
  — the same reason `Policy.slot_interval_minutes/1` is a single shared
  resolver.

  A nil profile yields no trips rather than raising, so the demo provider and
  any caller without a resolved organiser behave as they did before.
  """
  @spec put_travel_periods(map(), map() | nil, Date.t(), Date.t()) :: map()
  def put_travel_periods(config, nil, _first_date, _last_date),
    do: Map.put(config, :travel_periods, [])

  def put_travel_periods(config, %{id: profile_id}, first_date, last_date)
      when is_integer(profile_id) do
    Map.put(config, :travel_periods, Travel.for_window(profile_id, first_date, last_date))
  end

  def put_travel_periods(config, _organizer_profile, _first_date, _last_date),
    do: Map.put(config, :travel_periods, [])
```

- [ ] **Step 6: Call it at both `schedule_config/4` call sites**

In `get_available_slots/6` (around `availability_helpers.ex:101`), the single date is both ends of the window:

```elixir
            config =
              schedule
              |> schedule_config(
                meeting_type,
                build_limit_checker(organizer_user_id, organizer_profile, context, date, date),
                duration_minutes
              )
              |> put_travel_periods(organizer_profile, date, date)
```

In the range-availability function (around `availability_helpers.ex:195`), pad by one day at each end to match the ±1 day the engine already prefetches for midnight-straddling windows:

```elixir
                config =
                  schedule
                  |> schedule_config(meeting_type, limit_checker, duration_minutes)
                  |> put_travel_periods(
                    organizer_profile,
                    Date.add(start_date, -1),
                    Date.add(end_date, 1)
                  )
```

- [ ] **Step 7: Run the gate test**

Run: `mix test test/tymeslot/availability/travel_path_agreement_test.exs`
Expected: PASS, 8 tests

- [ ] **Step 8: Verify Stage 2 as a whole**

Run: `mix test && mix credo --strict && mix format --check-formatted && mix dialyzer`
Expected: all pass. The full suite matters here: `Profiles.get_profile_settings/1` and `Policy.scheduling_config/2` are consumed outside availability.

- [ ] **Step 9: Commit**

```bash
git add lib/tymeslot/profiles.ex lib/tymeslot/bookings/policy.ex \
        lib/tymeslot_web/live/scheduling/availability_helpers.ex \
        test/tymeslot/availability/travel_path_agreement_test.exs
git commit -m "feat(availability): resolve travel periods on both the display and submit paths"
```

---

### Task 7b: DST and policy invariants inside a trip

Closes the two spec testing requirements — a trip straddling a DST boundary, and
policy continuing to come from the meeting type's schedule — that the tasks above
do not otherwise assert.

**Files:**
- Test: `test/tymeslot/availability/travel_dst_and_policy_test.exs`

**Interfaces:**
- Consumes: everything from Tasks 1-7. No production code changes; if either test
  fails, the defect is in Task 5 or Task 7 and belongs fixed there.

- [ ] **Step 1: Write the test**

Create `test/tymeslot/availability/travel_dst_and_policy_test.exs`:

```elixir
defmodule Tymeslot.Availability.TravelDstAndPolicyTest do
  use Tymeslot.DataCase, async: true

  @moduletag :availability
  @moduletag :integration

  import Tymeslot.Factory

  alias Tymeslot.Availability.BusinessHours
  alias Tymeslot.Availability.Calculate
  alias Tymeslot.Availability.Travel
  alias Tymeslot.Bookings.Policy

  @home "America/New_York"
  @away "Europe/Berlin"

  describe "a trip straddling a DST boundary" do
    # The EU moves to summer time on the last Sunday of March: 2027-03-28.
    # These dates are fixed deliberately — a DST test cannot use relative dates,
    # and nothing here depends on today, so the test does not rot.
    @before_switch ~D[2027-03-24]
    @after_switch ~D[2027-03-31]

    defp straddling_trip do
      [
        %{
          start_date: ~D[2027-03-22],
          end_date: ~D[2027-04-04],
          timezone: @away,
          days: [
            %{day_of_week: 3, is_available: true, start_time: ~T[10:00:00], end_time: ~T[16:00:00]}
          ]
        }
      ]
    end

    defp config do
      %{
        weekly_schedule: [
          %{
            day_of_week: 3,
            is_available: true,
            start_time: ~T[09:00:00],
            end_time: ~T[17:00:00],
            breaks: []
          }
        ],
        overrides: [],
        travel_periods: straddling_trip()
      }
    end

    test "reads 10:00 local on both sides of the switch" do
      for date <- [@before_switch, @after_switch] do
        assert {:ok, hours} =
                 BusinessHours.get_business_hours_in_timezone(date, 1, @home, @away, config())

        assert DateTime.to_time(hours.start_datetime) == ~T[10:00:00],
               "expected 10:00 Berlin local on #{date}"
      end
    end

    test "those two 10:00s are different instants, an hour apart in UTC" do
      instants =
        for date <- [@before_switch, @after_switch] do
          {:ok, hours} =
            BusinessHours.get_business_hours_in_timezone(date, 1, @home, "Etc/UTC", config())

          DateTime.to_time(hours.start_datetime)
        end

      # 10:00 CET is 09:00 UTC; 10:00 CEST is 08:00 UTC. Were the zone resolved
      # once and applied as a fixed offset, these would be equal.
      assert instants == [~T[09:00:00], ~T[08:00:00]]
    end
  end

  describe "scheduling policy during a trip" do
    defp policy_setup(advance_booking_days) do
      user = insert(:user)
      profile = insert(:profile, user: user, timezone: @home)

      schedule =
        insert(:availability_schedule,
          profile: profile,
          is_default: true,
          buffer_minutes: 0,
          min_advance_hours: 0,
          advance_booking_days: advance_booking_days
        )

      insert(:weekly_availability,
        schedule: schedule,
        day_of_week: 3,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )

      meeting_type =
        insert(:meeting_type,
          user: user,
          duration_minutes: 30,
          availability_schedule_id: schedule.id
        )

      base = Date.add(Date.utc_today(), 60)
      wednesday = Date.add(base, rem(10 - Date.day_of_week(base), 7))

      {:ok, trip} =
        Travel.create_period(profile, %{
          label: "Berlin",
          start_date: Date.add(wednesday, -2),
          end_date: Date.add(wednesday, 2),
          timezone: @away
        })

      {:ok, _day} =
        Travel.set_day(profile, trip, %{
          day_of_week: 3,
          is_available: true,
          start_time: ~T[10:00:00],
          end_time: ~T[16:00:00]
        })

      %{user: user, meeting_type: meeting_type, wednesday: wednesday}
    end

    test "the schedule's booking horizon still gates a trip date" do
      %{user: user, meeting_type: meeting_type, wednesday: wednesday} = policy_setup(10)

      config = Policy.scheduling_config(user.id, meeting_type)

      assert config.max_advance_booking_days == 10

      # The trip date is 60-plus days out, well beyond a 10-day horizon. A trip
      # supplies hours and a zone, never policy.
      assert {:ok, []} =
               Calculate.available_slots(wednesday, 30, @home, config.owner_timezone, [], config)
    end

    test "the same trip date is offered once the horizon allows it" do
      %{user: user, meeting_type: meeting_type, wednesday: wednesday} = policy_setup(365)

      config = Policy.scheduling_config(user.id, meeting_type)

      assert {:ok, slots} =
               Calculate.available_slots(wednesday, 30, @home, config.owner_timezone, [], config)

      refute slots == []
    end
  end
end
```

- [ ] **Step 2: Run the test**

Run: `mix test test/tymeslot/availability/travel_dst_and_policy_test.exs`
Expected: PASS, 4 tests. A failure here is a defect in Task 5 (per-date zone resolution) or Task 7 (config wiring), not in this test.

- [ ] **Step 3: Commit**

```bash
git add test/tymeslot/availability/travel_dst_and_policy_test.exs
git commit -m "test(availability): pin DST and policy behaviour inside travel periods"
```


---

# Stage 3 — Host-facing display

Independently verifiable: while a trip covers today, the host's own views and notifications read in the trip's zone. Booker-facing pages are untouched throughout.

### Task 8: `Travel.timezone_on/2` and `Travel.timezone_for_user_on/2`

**Files:**
- Modify: `lib/tymeslot/availability/travel.ex`
- Test: `test/tymeslot/availability/travel_timezone_on_test.exs`

**Interfaces:**
- Consumes: `TravelPeriodQueries.list_overlapping/3` (Task 2)
- Produces:
  - `Travel.timezone_on(ProfileSchema.t(), Date.t()) :: String.t()`
  - `Travel.timezone_for_user_on(user_id :: integer() | nil, Date.t()) :: String.t()`

These live in `Travel` rather than in `Profiles` so the dependency runs one way only: `Availability` already depends on `Profiles`, and trips stay owned by the availability domain.

- [ ] **Step 1: Write the failing test**

Create `test/tymeslot/availability/travel_timezone_on_test.exs`:

```elixir
defmodule Tymeslot.Availability.TravelTimezoneOnTest do
  use Tymeslot.DataCase, async: true

  @moduletag :availability
  @moduletag :unit

  import Tymeslot.Factory

  alias Tymeslot.Availability.Travel
  alias Tymeslot.Profiles

  describe "timezone_on/2" do
    test "returns the trip zone for a date inside a trip" do
      profile = insert(:profile, timezone: "America/New_York")

      insert(:travel_period,
        profile: profile,
        start_date: ~D[2027-03-14],
        end_date: ~D[2027-03-28],
        timezone: "Europe/Berlin"
      )

      assert Travel.timezone_on(profile, ~D[2027-03-17]) == "Europe/Berlin"
    end

    test "returns the profile zone outside every trip" do
      profile = insert(:profile, timezone: "America/New_York")

      insert(:travel_period,
        profile: profile,
        start_date: ~D[2027-03-14],
        end_date: ~D[2027-03-28],
        timezone: "Europe/Berlin"
      )

      assert Travel.timezone_on(profile, ~D[2027-04-07]) == "America/New_York"
    end

    test "falls back to the default when the profile has no zone" do
      profile = insert(:profile, timezone: nil)

      assert Travel.timezone_on(profile, ~D[2027-03-17]) == Profiles.get_default_timezone()
    end
  end

  describe "timezone_for_user_on/2" do
    test "resolves through the user's profile" do
      user = insert(:user)
      profile = insert(:profile, user: user, timezone: "America/New_York")

      insert(:travel_period,
        profile: profile,
        start_date: ~D[2027-03-14],
        end_date: ~D[2027-03-28],
        timezone: "Europe/Berlin"
      )

      assert Travel.timezone_for_user_on(user.id, ~D[2027-03-17]) == "Europe/Berlin"
      assert Travel.timezone_for_user_on(user.id, ~D[2027-04-07]) == "America/New_York"
    end

    test "returns the default for a nil user" do
      assert Travel.timezone_for_user_on(nil, ~D[2027-03-17]) == Profiles.get_default_timezone()
    end

    test "returns the default for a user with no profile" do
      user = insert(:user)

      assert Travel.timezone_for_user_on(user.id, ~D[2027-03-17]) ==
               Profiles.get_default_timezone()
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/tymeslot/availability/travel_timezone_on_test.exs`
Expected: FAIL — `function Travel.timezone_on/2 is undefined`

- [ ] **Step 3: Add both functions to `Travel`**

In `lib/tymeslot/availability/travel.ex`, add `alias Tymeslot.Profiles` and `alias Tymeslot.Profiles.ProfileQueries` in alphabetical position, then add:

```elixir
  @doc """
  The zone the profile is on for a given date: the covering trip's zone, else
  the profile's own.

  The date matters, and which date to pass depends on the question being asked.
  "What time is it for me now" — the dashboard grid, desktop reminders — passes
  today. "When will this meeting be for me" — host-facing emails — passes the
  meeting's own date, so a booking made at home for a date abroad is announced
  in the zone the host will actually be in.
  """
  @spec timezone_on(ProfileSchema.t(), Date.t()) :: String.t()
  def timezone_on(%ProfileSchema{} = profile, date) do
    home = profile.timezone || Profiles.get_default_timezone()

    case TravelPeriodQueries.list_overlapping(profile.id, date, date) do
      [period | _rest] -> period.timezone
      [] -> home
    end
  end

  @doc """
  `timezone_on/2` for a caller that holds only a user id.
  """
  @spec timezone_for_user_on(integer() | nil, Date.t()) :: String.t()
  def timezone_for_user_on(nil, _date), do: Profiles.get_default_timezone()

  def timezone_for_user_on(user_id, date) do
    case ProfileQueries.get_by_user_id(user_id) do
      {:ok, profile} -> timezone_on(profile, date)
      {:error, :not_found} -> Profiles.get_default_timezone()
    end
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/tymeslot/availability/travel_timezone_on_test.exs`
Expected: PASS, 6 tests

- [ ] **Step 5: Commit**

```bash
git add lib/tymeslot/availability/travel.ex \
        test/tymeslot/availability/travel_timezone_on_test.exs
git commit -m "feat(availability): resolve the host's zone for a given date"
```

---

### Task 9: Host emails read in the meeting's zone

**Files:**
- Modify: `lib/tymeslot/emails/appointment_builder.ex:69-81`
- Modify: `lib/tymeslot/emails/email_service/calendar_emails.ex:134-136`
- Test: `test/tymeslot/emails/appointment_builder_travel_test.exs`

**Interfaces:**
- Consumes: `Travel.timezone_for_user_on/2` from Task 8
- Produces: no signature changes

- [ ] **Step 1: Write the failing test**

Create `test/tymeslot/emails/appointment_builder_travel_test.exs`:

```elixir
defmodule Tymeslot.Emails.AppointmentBuilderTravelTest do
  use Tymeslot.DataCase, async: true

  @moduletag :emails
  @moduletag :unit

  import Tymeslot.Factory

  alias Tymeslot.Availability.Travel

  describe "owner timezone resolution" do
    test "a meeting during a trip resolves to the trip zone even when booked from home" do
      user = insert(:user)
      profile = insert(:profile, user: user, timezone: "America/New_York")

      {:ok, trip} =
        Travel.create_period(profile, %{
          label: "Berlin",
          start_date: ~D[2027-03-14],
          end_date: ~D[2027-03-28],
          timezone: "Europe/Berlin"
        })

      assert trip.timezone == "Europe/Berlin"

      # The meeting falls inside the trip; "now" is irrelevant to the answer.
      assert Travel.timezone_for_user_on(user.id, ~D[2027-03-17]) == "Europe/Berlin"

      # A meeting after the trip is announced in the home zone.
      assert Travel.timezone_for_user_on(user.id, ~D[2027-04-07]) == "America/New_York"
    end
  end
end
```

- [ ] **Step 2: Run test to verify it passes already**

Run: `mix test test/tymeslot/emails/appointment_builder_travel_test.exs`
Expected: PASS — this test pins `Travel`'s behaviour, which Task 8 delivered. It is here so the email change has a named guarantee to build on. The behaviour change itself is verified by the full suite in Step 5.

- [ ] **Step 3: Change `appointment_builder.ex`**

Add `alias Tymeslot.Availability.Travel` in alphabetical position, then replace `owner_timezone/1`:

```elixir
  # Keyed on the meeting's own date rather than today: a February booking for a
  # March trip is announced in the zone the host will be in when it happens.
  defp owner_timezone(meeting) do
    case meeting.organizer_user_id do
      nil ->
        Logger.error("Missing organizer_user_id for meeting, using default timezone",
          meeting_uid: meeting.uid
        )

        @default_timezone

      user_id ->
        Travel.timezone_for_user_on(user_id, DateTime.to_date(meeting.start_time))
    end
  end
```

- [ ] **Step 4: Change `calendar_emails.ex`**

Add `alias Tymeslot.Availability.Travel` in alphabetical position, then replace the three `resolve_owner_timezone/1` clauses:

```elixir
  defp resolve_owner_timezone(%{organizer_user_id: nil}), do: Profiles.get_default_timezone()

  defp resolve_owner_timezone(%{organizer_user_id: id, start_time: %DateTime{} = start_time}),
    do: Travel.timezone_for_user_on(id, DateTime.to_date(start_time))

  defp resolve_owner_timezone(%{organizer_user_id: id}), do: Profiles.get_user_timezone(id)
  defp resolve_owner_timezone(_meeting), do: Profiles.get_default_timezone()
```

- [ ] **Step 5: Run the email suite**

Run: `mix test test/tymeslot/emails/ && mix test test/tymeslot/availability/`
Expected: PASS. Accounts with no trips resolve exactly as before, so existing email tests are unaffected.

- [ ] **Step 6: Commit**

```bash
git add lib/tymeslot/emails/appointment_builder.ex \
        lib/tymeslot/emails/email_service/calendar_emails.ex \
        test/tymeslot/emails/appointment_builder_travel_test.exs
git commit -m "feat(emails): announce host times in the zone in effect on the meeting's date"
```

---

### Task 10: Dashboard grid and reminders follow today's zone

**Files:**
- Modify: `lib/tymeslot_web/live/dashboard/calendar_grid/helpers/data_loading.ex:123-134` — `assign_timezone/1`
- Modify: `lib/tymeslot_web/live/dashboard/calendar_grid/views/status_banners.ex` — add the active-trip banner
- Test: `test/tymeslot_web/live/dashboard/calendar_grid_travel_test.exs`

**Interfaces:**
- Consumes: `Travel.timezone_on/2` from Task 8
- Produces: no new public functions

- [ ] **Step 2: Write the failing test**

Create `test/tymeslot_web/live/dashboard/calendar_grid_travel_test.exs`:

```elixir
defmodule TymeslotWeb.Live.Dashboard.CalendarGridTravelTest do
  use Tymeslot.DataCase, async: true

  @moduletag :live
  @moduletag :availability

  import Tymeslot.Factory

  alias Tymeslot.Availability.Travel

  describe "the grid's zone" do
    test "is the trip zone while a trip covers today" do
      profile = insert(:profile, timezone: "America/New_York")
      today = Date.utc_today()

      {:ok, _trip} =
        Travel.create_period(profile, %{
          label: "Berlin now",
          start_date: Date.add(today, -1),
          end_date: Date.add(today, 5),
          timezone: "Europe/Berlin"
        })

      assert Travel.timezone_on(profile, today) == "Europe/Berlin"
    end

    test "is the home zone when no trip covers today" do
      profile = insert(:profile, timezone: "America/New_York")
      today = Date.utc_today()

      {:ok, _trip} =
        Travel.create_period(profile, %{
          label: "Berlin later",
          start_date: Date.add(today, 30),
          end_date: Date.add(today, 44),
          timezone: "Europe/Berlin"
        })

      assert Travel.timezone_on(profile, today) == "America/New_York"
    end
  end
end
```

- [ ] **Step 3: Run test to verify it passes**

Run: `mix test test/tymeslot_web/live/dashboard/calendar_grid_travel_test.exs`
Expected: PASS — the resolver from Task 8 already provides this. The test names the contract the grid now depends on.

- [ ] **Step 4: Change the grid's zone source**

In `lib/tymeslot_web/live/dashboard/calendar_grid/helpers/data_loading.ex`, add `alias Tymeslot.Availability.Travel` in alphabetical position and replace `assign_timezone/1`:

```elixir
  @spec assign_timezone(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_timezone(socket) do
    assigns = socket.assigns
    active_period = active_travel_period(assigns[:profile])

    # A trip covering today wins over the profile's own zone; the rest of the
    # chain is unchanged, so an account with no trips resolves exactly as before.
    raw_tz =
      (active_period && active_period.timezone) ||
        get_in(assigns, [:profile, Access.key(:timezone)]) ||
        Timezones.fallback()

    user_id = get_in(assigns, [:current_user, Access.key(:id)])
    tz = Timezones.validate_or_utc(raw_tz, user_id: user_id)

    socket
    |> assign(:user_timezone, tz)
    |> assign(:active_travel_period, active_period)
    |> assign(:timezone_display, Timezones.format(tz))
    |> assign(:timezone_country_code, Timezones.country_code(tz))
  end

  # Today is taken in UTC rather than in the host's own zone, because which zone
  # that is, is what this function is resolving. The consequence is a window of
  # a few hours around a trip's first or last midnight where the grid may still
  # show the other zone; it corrects itself on the next load.
  defp active_travel_period(%{id: profile_id}) when is_integer(profile_id) do
    today = Date.utc_today()

    case Travel.for_window(profile_id, today, today) do
      [period | _rest] -> period
      [] -> nil
    end
  end

  defp active_travel_period(_profile), do: nil
```

Today's date is correct here rather than any displayed date: the grid answers "what time is it for me now", and a week view spanning a return date must not mix two zones in one hour-row grid. The `:active_travel_period` assign is what the banner in Step 5 renders.

- [ ] **Step 5: Add the active-trip banner**

In `lib/tymeslot_web/live/dashboard/calendar_grid/views/status_banners.ex`, add a banner rendered when a trip covers today, following the file's existing banner markup and using `<%!-- --%>` for any comment:

```elixir
  attr :active_trip, :map, default: nil

  @spec travel_banner(map()) :: Phoenix.LiveView.Rendered.t()
  def travel_banner(assigns) do
    ~H"""
    <div
      :if={@active_trip}
      class="flex items-center gap-2 rounded-token-lg bg-turquoise-50 px-4 py-2 text-token-sm text-turquoise-800"
    >
      <.icon name="hero-globe-europe-africa" class="w-4 h-4 shrink-0" />
      <span>
        {dgettext("dashboard_calendar", "Showing times in %{zone} — %{label}",
          zone: @active_trip.timezone,
          label: @active_trip.label
        )}
      </span>
    </div>
    """
  end
```

Without this the grid silently shifts by hours and reads as a bug.

- [ ] **Step 6: Run the dashboard and availability suites**

Run: `mix test test/tymeslot_web/live/dashboard/ && mix test test/tymeslot/availability/`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add lib/tymeslot_web/live/dashboard/calendar_grid/ \
        test/tymeslot_web/live/dashboard/calendar_grid_travel_test.exs
git commit -m "feat(dashboard): show the calendar in the zone in effect today"
```

---

# Stage 4 — The trip editor UI

Independently verifiable: trips can be created, edited and deleted from the availability page. Stages 1–3 already make them take effect.

### Task 11: The Travel section

**Files:**
- Create: `lib/tymeslot_web/live/dashboard/availability/travel_section.ex`
- Modify: `lib/tymeslot_web/live/dashboard/schedule_settings_component.ex` — assign trips and render the section
- Test: `test/tymeslot_web/live/dashboard/travel_section_test.exs`

**Interfaces:**
- Consumes: `Travel.list_for_profile/1`, `Travel.delete_period/2` from Task 3
- Produces: `TravelSection.travel_section/1` function component, attrs `:periods` (list), `:myself` (any)

- [ ] **Step 1: Write the failing test**

Create `test/tymeslot_web/live/dashboard/travel_section_test.exs`:

```elixir
defmodule TymeslotWeb.Live.Dashboard.TravelSectionTest do
  use Tymeslot.DataCase, async: true

  @moduletag :live
  @moduletag :components

  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias TymeslotWeb.Live.Dashboard.Availability.TravelSection

  describe "travel_section/1" do
    test "lists each trip with its label, dates and zone" do
      period =
        build(:travel_period,
          label: "Berlin, spring",
          start_date: ~D[2027-03-14],
          end_date: ~D[2027-03-28],
          timezone: "Europe/Berlin"
        )

      html =
        render_component(&TravelSection.travel_section/1, periods: [period], myself: nil)

      assert html =~ "Berlin, spring"
      assert html =~ "Europe/Berlin"
    end

    test "shows an empty state when there are no trips" do
      html = render_component(&TravelSection.travel_section/1, periods: [], myself: nil)

      assert html =~ "No trips"
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/tymeslot_web/live/dashboard/travel_section_test.exs`
Expected: FAIL — module not available

- [ ] **Step 3: Write the component**

Create `lib/tymeslot_web/live/dashboard/availability/travel_section.ex`:

```elixir
defmodule TymeslotWeb.Live.Dashboard.Availability.TravelSection do
  @moduledoc """
  Lists a profile's travel periods on the availability page.

  A trip is a date range with its own timezone and weekly hours, applying to
  every meeting type for the dates it covers. There is no cap on trips: the
  5-schedule cap exists because schedules render as a tab strip, and a list has
  no such constraint.
  """
  use TymeslotWeb, :html

  attr :periods, :list, required: true
  attr :myself, :any, required: true

  @spec travel_section(map()) :: Phoenix.LiveView.Rendered.t()
  def travel_section(assigns) do
    ~H"""
    <section class="space-y-4">
      <div class="flex items-center justify-between gap-4">
        <div>
          <h3 class="text-token-base font-semibold text-tymeslot-800">
            {dgettext("dashboard_availability", "Travel")}
          </h3>
          <p class="text-token-sm text-tymeslot-500">
            {dgettext(
              "dashboard_availability",
              "Dates when you are in another timezone, with the hours you are bookable there."
            )}
          </p>
        </div>

        <button
          type="button"
          class="btn btn-secondary shrink-0"
          phx-click="show_travel_form"
          phx-target={@myself}
        >
          {dgettext("dashboard_availability", "Add a trip")}
        </button>
      </div>

      <p :if={@periods == []} class="text-token-sm text-tymeslot-400">
        {dgettext("dashboard_availability", "No trips yet.")}
      </p>

      <ul :if={@periods != []} class="space-y-2">
        <li
          :for={period <- @periods}
          class="flex items-center justify-between gap-4 rounded-token-lg border-2 border-tymeslot-50 bg-white p-3"
        >
          <div class="min-w-0">
            <p class="truncate text-token-sm font-semibold text-tymeslot-800">{period.label}</p>
            <p class="text-token-xs text-tymeslot-500">
              {Calendar.strftime(period.start_date, "%d %b %Y")} –
              {Calendar.strftime(period.end_date, "%d %b %Y")} · {period.timezone}
            </p>
          </div>

          <div class="flex shrink-0 items-center gap-2">
            <button
              type="button"
              class="btn btn-ghost"
              phx-click="show_travel_form"
              phx-value-id={period.id}
              phx-target={@myself}
            >
              {dgettext("dashboard_availability", "Edit")}
            </button>
            <button
              type="button"
              class="btn btn-ghost"
              phx-click="delete_travel_period"
              phx-value-id={period.id}
              phx-target={@myself}
            >
              {dgettext("dashboard_availability", "Delete")}
            </button>
          </div>
        </li>
      </ul>
    </section>
    """
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/tymeslot_web/live/dashboard/travel_section_test.exs`
Expected: PASS, 2 tests

- [ ] **Step 5: Mount it in the availability page**

In `lib/tymeslot_web/live/dashboard/schedule_settings_component.ex`:

Add the alias in alphabetical position:

```elixir
  alias Tymeslot.Availability.Travel
  alias TymeslotWeb.Live.Dashboard.Availability.TravelSection
```

Add a loader beside `load_schedules/1`:

```elixir
  @spec load_travel_periods(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp load_travel_periods(socket) do
    assign(socket, :travel_periods, Travel.list_for_profile(socket.assigns.profile.id))
  end
```

Call it from `update/2` alongside `load_schedules/1`, then render the section inside `render/1`, after the closing `</ScheduleSwitcher.schedule_panel>` and before the modals:

```elixir
      <TravelSection.travel_section periods={@travel_periods} myself={@myself} />
```

And add the delete handler beside the other `handle_event/3` clauses:

```elixir
  def handle_event("delete_travel_period", %{"id" => id}, socket) do
    profile = socket.assigns.profile

    with {:ok, period_id} <- parse_travel_id(id),
         period when not is_nil(period) <-
           Enum.find(socket.assigns.travel_periods, &(&1.id == period_id)),
         {:ok, _deleted} <- Travel.delete_period(profile, period) do
      {:noreply, load_travel_periods(socket)}
    else
      _unknown -> {:noreply, socket}
    end
  end

  defp parse_travel_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> {:ok, parsed}
      _other -> :error
    end
  end

  defp parse_travel_id(_id), do: :error
```

Finding the trip in the already-loaded list rather than fetching by id is what scopes the delete to this profile: an id belonging to someone else is simply not in the list.

- [ ] **Step 6: Run the dashboard suite**

Run: `mix test test/tymeslot_web/live/dashboard/`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add lib/tymeslot_web/live/dashboard/availability/travel_section.ex \
        lib/tymeslot_web/live/dashboard/schedule_settings_component.ex \
        test/tymeslot_web/live/dashboard/travel_section_test.exs
git commit -m "feat(dashboard): list travel periods on the availability page"
```

---

### Task 12: The trip editor form

**Files:**
- Create: `lib/tymeslot_web/live/dashboard/availability/travel_form.ex`
- Modify: `lib/tymeslot_web/live/dashboard/schedule_settings_component.ex` — form state and save handler
- Test: `test/tymeslot_web/live/dashboard/travel_form_test.exs`

**Interfaces:**
- Consumes: `Travel.create_period/2`, `Travel.update_period/3`, `Travel.set_day/3` (Task 3); `Timezones.all_options/0`
- Produces: `TravelForm.travel_form_modal/1` function component, attrs `:id`, `:show`, `:period`, `:timezone_options`, `:form_errors`, `:myself`, `:on_cancel`

- [ ] **Step 1: Write the failing test**

Create `test/tymeslot_web/live/dashboard/travel_form_test.exs`:

```elixir
defmodule TymeslotWeb.Live.Dashboard.TravelFormTest do
  use Tymeslot.DataCase, async: true

  @moduletag :live
  @moduletag :components

  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias TymeslotWeb.Live.Dashboard.Availability.TravelForm

  defp assigns(overrides) do
    Map.merge(
      %{
        id: "travel-form",
        show: true,
        period: nil,
        timezone_options: [{"Europe/Berlin", "Europe/Berlin"}],
        form_errors: %{},
        myself: nil,
        on_cancel: %Phoenix.LiveView.JS{}
      },
      overrides
    )
  end

  describe "travel_form_modal/1" do
    test "renders empty date and label fields for a new trip" do
      html = render_component(&TravelForm.travel_form_modal/1, assigns(%{}))

      assert html =~ ~s(name="label")
      assert html =~ ~s(name="start_date")
      assert html =~ ~s(name="end_date")
      assert html =~ ~s(name="timezone")
    end

    test "prefills the fields when editing an existing trip" do
      period =
        build(:travel_period,
          label: "Berlin, spring",
          start_date: ~D[2027-03-14],
          end_date: ~D[2027-03-28],
          timezone: "Europe/Berlin"
        )

      html = render_component(&TravelForm.travel_form_modal/1, assigns(%{period: period}))

      assert html =~ "Berlin, spring"
      assert html =~ "2027-03-14"
      assert html =~ "2027-03-28"
    end

    test "renders a row per weekday" do
      html = render_component(&TravelForm.travel_form_modal/1, assigns(%{}))

      for day_of_week <- 1..7 do
        assert html =~ ~s(name="days[#{day_of_week}][is_available]")
      end
    end

    test "shows a field error" do
      html =
        render_component(
          &TravelForm.travel_form_modal/1,
          assigns(%{form_errors: %{start_date: "overlaps an existing trip"}})
        )

      assert html =~ "overlaps an existing trip"
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/tymeslot_web/live/dashboard/travel_form_test.exs`
Expected: FAIL — module not available

- [ ] **Step 3: Write the form component**

Create `lib/tymeslot_web/live/dashboard/availability/travel_form.ex`:

```elixir
defmodule TymeslotWeb.Live.Dashboard.Availability.TravelForm do
  @moduledoc """
  Create and edit a travel period: label, inclusive date range, timezone, and
  one bookable-hours row per weekday.

  The weekday rows mirror the schedule editor's, because
  `Tymeslot.Availability.TravelPeriodDaySchema` deliberately mirrors
  `WeeklyAvailabilitySchema`. A weekday left unticked is simply not bookable
  during the trip.
  """
  use TymeslotWeb, :html

  @weekdays [
    {1, "Monday"},
    {2, "Tuesday"},
    {3, "Wednesday"},
    {4, "Thursday"},
    {5, "Friday"},
    {6, "Saturday"},
    {7, "Sunday"}
  ]

  attr :id, :string, required: true
  attr :show, :boolean, required: true
  attr :period, :map, default: nil
  attr :timezone_options, :list, required: true
  attr :form_errors, :map, default: %{}
  attr :myself, :any, required: true
  attr :on_cancel, :any, required: true

  @spec travel_form_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def travel_form_modal(assigns) do
    assigns = assign(assigns, :weekdays, @weekdays)

    ~H"""
    <TymeslotWeb.Components.CoreComponents.modal id={@id} show={@show} on_cancel={@on_cancel}>
      <form phx-submit="save_travel_period" phx-target={@myself} class="space-y-5">
        <input :if={@period} type="hidden" name="id" value={@period.id} />

        <div>
          <label for="travel-label" class="text-token-sm font-semibold text-tymeslot-700">
            {dgettext("dashboard_availability", "Label")}
          </label>
          <input
            id="travel-label"
            type="text"
            name="label"
            value={@period && @period.label}
            maxlength="60"
            required
            class="input w-full"
          />
          <p :if={@form_errors[:label]} class="text-token-xs text-red-600">{@form_errors[:label]}</p>
        </div>

        <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <div>
            <label for="travel-start" class="text-token-sm font-semibold text-tymeslot-700">
              {dgettext("dashboard_availability", "First day")}
            </label>
            <input
              id="travel-start"
              type="date"
              name="start_date"
              value={@period && Date.to_iso8601(@period.start_date)}
              required
              class="input w-full"
            />
            <p :if={@form_errors[:start_date]} class="text-token-xs text-red-600">
              {@form_errors[:start_date]}
            </p>
          </div>

          <div>
            <label for="travel-end" class="text-token-sm font-semibold text-tymeslot-700">
              {dgettext("dashboard_availability", "Last day")}
            </label>
            <input
              id="travel-end"
              type="date"
              name="end_date"
              value={@period && Date.to_iso8601(@period.end_date)}
              required
              class="input w-full"
            />
            <p :if={@form_errors[:end_date]} class="text-token-xs text-red-600">
              {@form_errors[:end_date]}
            </p>
          </div>
        </div>

        <div>
          <label for="travel-timezone" class="text-token-sm font-semibold text-tymeslot-700">
            {dgettext("dashboard_availability", "Timezone while there")}
          </label>
          <select id="travel-timezone" name="timezone" required class="input w-full">
            <option
              :for={{value, label} <- @timezone_options}
              value={value}
              selected={@period && @period.timezone == value}
            >
              {label}
            </option>
          </select>
          <p :if={@form_errors[:timezone]} class="text-token-xs text-red-600">
            {@form_errors[:timezone]}
          </p>
        </div>

        <fieldset class="space-y-2">
          <legend class="text-token-sm font-semibold text-tymeslot-700">
            {dgettext("dashboard_availability", "Bookable hours while there")}
          </legend>

          <div :for={{day_of_week, name} <- @weekdays} class="flex items-center gap-3">
            <label class="flex w-32 items-center gap-2 text-token-sm text-tymeslot-700">
              <input
                type="checkbox"
                name={"days[#{day_of_week}][is_available]"}
                value="true"
                checked={day_available?(@period, day_of_week)}
              />
              {name}
            </label>

            <input
              type="time"
              name={"days[#{day_of_week}][start_time]"}
              value={day_time(@period, day_of_week, :start_time)}
              class="input"
            />
            <span class="text-tymeslot-400">–</span>
            <input
              type="time"
              name={"days[#{day_of_week}][end_time]"}
              value={day_time(@period, day_of_week, :end_time)}
              class="input"
            />
          </div>
        </fieldset>

        <div class="flex justify-end gap-2">
          <button type="button" class="btn btn-ghost" phx-click={@on_cancel}>
            {dgettext("dashboard_availability", "Cancel")}
          </button>
          <button type="submit" class="btn btn-primary">
            {dgettext("dashboard_availability", "Save trip")}
          </button>
        </div>
      </form>
    </TymeslotWeb.Components.CoreComponents.modal>
    """
  end

  defp day_available?(nil, _day_of_week), do: false

  defp day_available?(period, day_of_week) do
    case find_day(period, day_of_week) do
      nil -> false
      day -> day.is_available
    end
  end

  defp day_time(nil, _day_of_week, _field), do: nil

  defp day_time(period, day_of_week, field) do
    case find_day(period, day_of_week) do
      nil -> nil
      day -> day |> Map.get(field) |> format_time()
    end
  end

  defp find_day(period, day_of_week) do
    days = if is_list(period.days), do: period.days, else: []
    Enum.find(days, &(&1.day_of_week == day_of_week))
  end

  defp format_time(nil), do: nil
  defp format_time(%Time{} = time), do: time |> Time.truncate(:second) |> Time.to_iso8601()
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/tymeslot_web/live/dashboard/travel_form_test.exs`
Expected: PASS, 4 tests

- [ ] **Step 5: Wire the form into the component**

In `lib/tymeslot_web/live/dashboard/schedule_settings_component.ex`, add the alias `alias TymeslotWeb.Live.Dashboard.Availability.TravelForm` and `alias Tymeslot.Timezones`, assign `show_travel_form: false` and `travel_form_period: nil` in `update/2`, render the modal beside the others, and add these handlers:

```elixir
  def handle_event("show_travel_form", params, socket) do
    period =
      case parse_travel_id(params["id"]) do
        {:ok, id} -> Enum.find(socket.assigns.travel_periods, &(&1.id == id))
        :error -> nil
      end

    {:noreply,
     socket
     |> assign(:show_travel_form, true)
     |> assign(:travel_form_period, period)
     |> assign(:form_errors, %{})}
  end

  def handle_event("hide_travel_form", _params, socket) do
    {:noreply, assign(socket, show_travel_form: false, travel_form_period: nil)}
  end

  def handle_event("save_travel_period", params, socket) do
    profile = socket.assigns.profile

    attrs = %{
      label: params["label"],
      start_date: params["start_date"],
      end_date: params["end_date"],
      timezone: params["timezone"]
    }

    result =
      case socket.assigns.travel_form_period do
        nil -> Travel.create_period(profile, attrs)
        period -> Travel.update_period(profile, period, attrs)
      end

    case result do
      {:ok, period} ->
        save_days(profile, period, params["days"] || %{})

        {:noreply,
         socket
         |> assign(show_travel_form: false, travel_form_period: nil, form_errors: %{})
         |> load_travel_periods()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form_errors, travel_errors(changeset))}
    end
  end

  # Every weekday is written, so unticking one persists as "not bookable"
  # rather than leaving a stale row behind.
  defp save_days(profile, period, days) do
    Enum.each(1..7, fn day_of_week ->
      submitted = Map.get(days, Integer.to_string(day_of_week), %{})
      available = submitted["is_available"] in ["true", true]

      Travel.set_day(profile, period, %{
        day_of_week: day_of_week,
        is_available: available,
        start_time: if(available, do: submitted["start_time"]),
        end_time: if(available, do: submitted["end_time"])
      })
    end)
  end

  defp travel_errors(changeset) do
    Map.new(changeset.errors, fn {field, {message, _opts}} -> {field, message} end)
  end
```

The modal:

```elixir
      <TravelForm.travel_form_modal
        id="travel-form-modal"
        show={@show_travel_form}
        period={@travel_form_period}
        timezone_options={Timezones.all_options()}
        form_errors={@form_errors}
        myself={@myself}
        on_cancel={JS.push("hide_travel_form", target: @myself)}
      />
```

- [ ] **Step 6: Run the full verification**

Run: `mix test && mix credo --strict && mix format --check-formatted && mix dialyzer`
Expected: all pass

- [ ] **Step 7: Commit and push**

```bash
git add lib/tymeslot_web/live/dashboard/availability/travel_form.ex \
        lib/tymeslot_web/live/dashboard/schedule_settings_component.ex \
        test/tymeslot_web/live/dashboard/travel_form_test.exs
git commit -m "feat(dashboard): add the travel period editor"
git push -u origin feature/travel-periods
```

---

## Manual verification

After Stage 4, confirm the headline requirement by hand:

1. Set your profile timezone to `America/New_York`, with a default schedule of Mon–Fri 09:00–17:00.
2. Add a trip: label "Berlin", covering a fortnight roughly two months out, zone `Europe/Berlin`, Mon–Fri 10:00–16:00.
3. Open your public booking page **in a private window** with your browser zone set to New York.
4. Pick a date inside the trip: offered times should start at 10:00 Berlin, rendered in New York (04:00 or 05:00 depending on where both zones are in their DST cycles).
5. Pick a date after the trip ends: offered times should start at 09:00 New York.
6. Book the post-return slot. It must be accepted, not refused as "slot taken" — that is the two-path agreement holding in production rather than only in the test.
7. Check the confirmation email you receive: the meeting should read in the zone in effect on the meeting's own date.
