defmodule Tymeslot.BookingPages.BookingPageQueries do
  @moduledoc """
  Database access for booking pages.
  """
  import Ecto.Query, warn: false

  alias Tymeslot.BookingPages.BookingPageMeetingTypeSchema
  alias Tymeslot.BookingPages.BookingPageSchema
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
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
    query =
      from(l in BookingPageMeetingTypeSchema,
        where: l.booking_page_id == ^page_id and l.meeting_type_id == ^meeting_type_id
      )

    Repo.delete_all(query)

    :ok
  end

  @doc """
  The active meeting types listed on a page, in the host's order, preloaded
  as `MeetingTypeQueries.list_public_meeting_types/1` preloads them. Only types
  owned by the page's profile's user are listed, so a stray listing row for
  someone else's type is never shown.
  """
  @spec list_meeting_types(integer()) :: [MeetingTypeSchema.t()]
  def list_meeting_types(page_id) do
    query =
      from(mt in MeetingTypeSchema,
        join: l in BookingPageMeetingTypeSchema,
        on: l.meeting_type_id == mt.id,
        join: p in BookingPageSchema,
        on: p.id == l.booking_page_id,
        join: pr in assoc(p, :profile),
        where: l.booking_page_id == ^page_id and mt.is_active == true,
        where: mt.user_id == pr.user_id,
        order_by: [asc: mt.sort_order, asc: mt.name],
        preload: [:video_integration, :calendar_integration]
      )

    Repo.all(query)
  end

  @doc "Every `{meeting_type_id, page_id}` listing among a profile's pages."
  @spec memberships_for_profile(integer()) :: [{integer(), integer()}]
  def memberships_for_profile(profile_id) do
    query =
      from(l in BookingPageMeetingTypeSchema,
        join: p in BookingPageSchema,
        on: p.id == l.booking_page_id,
        where: p.profile_id == ^profile_id,
        select: {l.meeting_type_id, l.booking_page_id}
      )

    Repo.all(query)
  end

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
