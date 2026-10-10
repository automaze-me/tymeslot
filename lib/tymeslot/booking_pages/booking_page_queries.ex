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
    query =
      from(p in BookingPageSchema,
        where: p.profile_id == ^profile_id,
        order_by: [asc: p.inserted_at, asc: p.id]
      )

    Repo.all(query)
  end

  @doc "How many pages a profile holds."
  @spec count_for_profile(integer()) :: non_neg_integer()
  def count_for_profile(profile_id) do
    query = from(p in BookingPageSchema, where: p.profile_id == ^profile_id)
    Repo.aggregate(query, :count)
  end

  @doc "One of a profile's pages, scoped so an id can never reach another profile's."
  @spec get_for_profile(integer(), integer()) :: BookingPageSchema.t() | nil
  def get_for_profile(profile_id, id),
    do: Repo.get_by(BookingPageSchema, id: id, profile_id: profile_id)

  @doc "A page by id."
  @spec get(integer()) :: BookingPageSchema.t() | nil
  def get(id), do: Repo.get(BookingPageSchema, id)

  @doc """
  The page at `slug`, with `preload` loaded. Compared lowercase so the
  `lower(slug)` index is used.
  """
  @spec get_by_slug(String.t(), list()) :: BookingPageSchema.t() | nil
  def get_by_slug(slug, preload \\ []) do
    normalised = String.downcase(slug)

    query =
      from(p in BookingPageSchema,
        where: fragment("lower(?)", p.slug) == ^normalised,
        preload: ^preload
      )

    Repo.one(query)
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
  @spec delete(BookingPageSchema.t()) ::
          {:ok, BookingPageSchema.t()} | {:error, Ecto.Changeset.t()}
  def delete(page), do: Repo.delete(page)
end
