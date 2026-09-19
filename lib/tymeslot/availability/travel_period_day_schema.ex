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
