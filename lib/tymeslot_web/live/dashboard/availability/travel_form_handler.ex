defmodule TymeslotWeb.Live.Dashboard.Availability.TravelFormHandler do
  @moduledoc """
  Event handling for the travel period editor embedded in
  `TymeslotWeb.Dashboard.ScheduleSettingsComponent`.

  Unlike `TymeslotWeb.Dashboard.Availability.ListComponent.BreakHelpers`
  (pure, stateless functions called *from* `handle_event/3` clauses that
  stay in `ListComponent`), this module owns the `handle_event/3` clauses
  themselves: `handle_event/3` here takes and returns the host component's
  socket exactly as a clause defined directly in
  `ScheduleSettingsComponent` would, and that component's own `handle_event`
  only dispatches to it by event name — see `events/0`. It exists as its
  own module because "how a submitted trip form becomes `Travel` calls" is
  a large, cohesive unit that `ScheduleSettingsComponent` had no room left
  to hold inline.
  """
  import Phoenix.Component, only: [assign: 2, assign: 3]

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Availability.{AvailabilityActions, Travel}
  alias Tymeslot.Timezones
  alias Tymeslot.Utils.ChangesetUtils
  alias TymeslotWeb.Live.Shared.Flash

  @events ~w(
    show_travel_form
    hide_travel_form
    toggle_timezone_dropdown
    close_timezone_dropdown
    search_timezone
    change_timezone
    save_travel_period
  )

  @spec events() :: [String.t()]
  def events, do: @events

  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  # `params["id"]` is absent for "add a trip" and a `phx-value-id` string for
  # "edit" — both shapes travel_section.ex's single button emits. An id that
  # does not resolve in the already-loaded list is a no-op, matching
  # `DeleteModalHandler.with_travel_period/3`, rather than falling through to
  # the add-a-trip form — which a submit would then save as a new trip.
  def handle_event("show_travel_form", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.travel_periods, &(&1.id == parse_id(id))) do
      nil -> noreply(socket)
      period -> noreply(open_travel_form(socket, period))
    end
  end

  def handle_event("show_travel_form", _params, socket) do
    noreply(open_travel_form(socket, nil))
  end

  def handle_event("hide_travel_form", _params, socket) do
    socket
    |> assign(
      show_travel_form: false,
      travel_form_period: nil,
      travel_form_submitted: nil,
      travel_form_errors: %{}
    )
    |> noreply()
  end

  # The zone picker is `TimezoneDropdown`, the same component the profile
  # settings page uses, embedded in the travel form. It hardcodes these four
  # event names, so this handler owns them for as long as the travel form is
  # the only place on the availability page that renders it.
  def handle_event("toggle_timezone_dropdown", _params, socket) do
    socket
    |> assign(
      :travel_form_timezone_dropdown_open,
      not socket.assigns.travel_form_timezone_dropdown_open
    )
    |> noreply()
  end

  def handle_event("close_timezone_dropdown", _params, socket) do
    noreply(assign(socket, :travel_form_timezone_dropdown_open, false))
  end

  def handle_event("search_timezone", %{"value" => search}, socket) do
    noreply(assign(socket, :travel_form_timezone_search, search))
  end

  def handle_event("change_timezone", %{"timezone" => timezone}, socket) do
    socket =
      assign(socket, travel_form_timezone_dropdown_open: false, travel_form_timezone_search: "")

    if Timezones.valid?(timezone) do
      noreply(assign(socket, :travel_form_timezone, timezone))
    else
      errors =
        Map.put(
          socket.assigns.travel_form_errors,
          :timezone,
          dgettext("dashboard_availability", "Unknown timezone")
        )

      noreply(assign(socket, :travel_form_errors, errors))
    end
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
        finish_saving(socket, profile, period, params)

      {:error, changeset} ->
        socket
        |> assign(:travel_form_errors, travel_errors(changeset))
        |> assign(:travel_form_submitted, params)
        |> noreply()
    end
  end

  # Runs after the trip row itself is saved, writing every weekday's hours in
  # the same round trip. On success the form closes; on a per-day failure it
  # stays open (carrying the now-persisted trip, so a retry edits rather than
  # duplicates) and the failure is surfaced rather than swallowed — a checked
  # day whose hours silently failed to save is exactly the trap that leaves a
  # host unbookable without a word. Either way, `travel_form_submitted` keeps
  # whatever the host just typed on screen: `TravelForm` renders from it in
  # preference to the trip's saved fields whenever it is set, so a rejected
  # submission (an overlap, a bad day) never comes back blank.
  defp open_travel_form(socket, period) do
    socket
    |> assign(:show_travel_form, true)
    |> assign(:travel_form_period, period)
    |> assign(:travel_form_submitted, nil)
    |> assign(:travel_form_timezone, default_timezone(period, socket.assigns.profile))
    |> assign(:travel_form_timezone_dropdown_open, false)
    |> assign(:travel_form_timezone_search, "")
    |> assign(:travel_form_errors, %{})
  end

  defp finish_saving(socket, profile, period, params) do
    case save_days(profile, period, days_param(params["days"])) do
      :ok ->
        Flash.info(dgettext("dashboard_availability", "Trip saved"))

        socket
        |> assign(
          show_travel_form: false,
          travel_form_period: nil,
          travel_form_submitted: nil,
          travel_form_errors: %{}
        )
        |> reload_travel_periods()
        |> noreply()

      {:error, message} ->
        Flash.error(message)

        socket
        |> assign(:travel_form_period, period)
        |> assign(:travel_form_submitted, params)
        |> reload_travel_periods()
        |> noreply()
    end
  end

  defp reload_travel_periods(socket) do
    assign(socket, :travel_periods, Travel.list_for_profile(socket.assigns.profile.id))
  end

  # Every weekday is written, so unticking one persists as "not bookable"
  # rather than leaving a stale row behind.
  defp save_days(profile, period, days) do
    1..7
    |> Enum.map(&save_day(profile, period, days, &1))
    |> collect_day_errors()
  end

  defp save_day(profile, period, days, day_of_week) do
    submitted = weekday_attrs(days, day_of_week)
    available = submitted["is_available"] in ["true", true]

    attrs = %{
      day_of_week: day_of_week,
      is_available: available,
      start_time: if(available, do: blank_to_nil(submitted["start_time"])),
      end_time: if(available, do: blank_to_nil(submitted["end_time"]))
    }

    case Travel.set_day(profile, period, attrs) do
      {:ok, _day} -> :ok
      {:error, changeset} -> {:error, day_of_week, changeset}
    end
  end

  # A crafted `days[1]=x` submits a plain value rather than the expected
  # `is_available`/`start_time`/`end_time` map; treat it as "nothing
  # submitted for this day" instead of raising on `submitted["is_available"]`.
  defp weekday_attrs(days, day_of_week) do
    case Map.get(days, Integer.to_string(day_of_week)) do
      attrs when is_map(attrs) -> attrs
      _other -> %{}
    end
  end

  # A crafted submit can send `days` as something other than a map (or omit
  # it); either reads as "no days submitted" rather than raising in
  # `weekday_attrs/2`.
  defp days_param(days) when is_map(days), do: days
  defp days_param(_other), do: %{}

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp collect_day_errors(results) do
    case Enum.filter(results, &match?({:error, _day, _changeset}, &1)) do
      [] -> :ok
      failures -> {:error, day_error_message(failures)}
    end
  end

  defp day_error_message(failures) do
    Enum.map_join(failures, "; ", fn {:error, day_of_week, changeset} ->
      "#{AvailabilityActions.day_name(day_of_week)}: #{ChangesetUtils.get_first_error(changeset)}"
    end)
  end

  defp travel_errors(changeset) do
    Map.new(changeset.errors, fn {field, {message, _opts}} -> {field, message} end)
  end

  defp default_timezone(nil, profile), do: profile.timezone || Timezones.fallback()
  defp default_timezone(period, _profile), do: period.timezone

  # Mirrors `ScheduleSettingsComponent`'s own `parse_id/1`: permissive on
  # trailing garbage, passthrough for anything that is not a binary.
  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, _rest} -> int
      :error -> nil
    end
  end

  defp parse_id(id), do: id

  defp noreply(socket), do: {:noreply, socket}
end
