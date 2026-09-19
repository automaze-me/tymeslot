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
