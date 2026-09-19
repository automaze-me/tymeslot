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
