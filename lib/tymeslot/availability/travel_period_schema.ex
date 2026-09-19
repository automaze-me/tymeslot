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
