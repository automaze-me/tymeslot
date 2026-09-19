defmodule TymeslotWeb.Live.Dashboard.Availability.DeleteModalHandler do
  @moduledoc """
  Event handling for the two delete-confirmation modals on the availability
  page: a schedule and a travel period.

  Both follow the same shape — show (gather what the confirmation needs to
  say), hide, confirm (re-find the target in the already-loaded list, so an
  id belonging to another profile is simply not there, then delete and
  reload) — so they are kept together here rather than in
  `TymeslotWeb.Dashboard.ScheduleSettingsComponent`, the same reason the
  travel form's own event handling lives in
  `TymeslotWeb.Live.Dashboard.Availability.TravelFormHandler` beside it.
  Functions here take and return the host component's socket, exactly as a
  `handle_event/3` clause would; only the dispatch itself lives in the
  component.

  `ScheduleSettingsComponent.load_schedules/1` and `.patch_to_selected/1`
  are called back on that module (kept public there for this) rather than
  reimplemented here: a schedule deletion has to leave the page in exactly
  the state a tab switch or a rename does, and that state assembly is
  already non-trivial there.
  """
  import Phoenix.Component, only: [assign: 3]

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Availability.{Schedules, Travel}
  alias TymeslotWeb.Dashboard.ScheduleSettingsComponent
  alias TymeslotWeb.Hooks.ModalHook
  alias TymeslotWeb.Live.Dashboard.Availability.ScheduleFailureMessage
  alias TymeslotWeb.Live.Shared.Flash

  @events ~w(
    show_delete_schedule_modal
    hide_delete_schedule_modal
    confirm_delete_schedule
    show_delete_travel_modal
    hide_delete_travel_modal
    confirm_delete_travel_period
  )

  @spec events() :: [String.t()]
  def events, do: @events

  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("show_delete_schedule_modal", _params, socket) do
    case socket.assigns.selected_schedule do
      nil -> noreply(socket)
      schedule -> noreply(show_delete_schedule(socket, schedule))
    end
  end

  def handle_event("hide_delete_schedule_modal", _params, socket) do
    noreply(ModalHook.hide_modal(socket, :delete_schedule))
  end

  def handle_event("confirm_delete_schedule", _params, socket) do
    ModalHook.with_modal_data(socket, :delete_schedule, fn data ->
      case Enum.find(socket.assigns.schedules, &(&1.id == data.id)) do
        nil -> noreply(ModalHook.hide_modal(socket, :delete_schedule))
        schedule -> delete_schedule(socket, schedule)
      end
    end)
  end

  def handle_event("show_delete_travel_modal", %{"id" => id}, socket) do
    with_travel_period(socket, id, fn period ->
      noreply(
        ModalHook.show_modal(socket, :delete_travel_period, %{
          id: period.id,
          label: period.label
        })
      )
    end)
  end

  def handle_event("hide_delete_travel_modal", _params, socket) do
    noreply(ModalHook.hide_modal(socket, :delete_travel_period))
  end

  def handle_event("confirm_delete_travel_period", _params, socket) do
    ModalHook.with_modal_data(socket, :delete_travel_period, fn data ->
      case Enum.find(socket.assigns.travel_periods, &(&1.id == data.id)) do
        nil -> noreply(ModalHook.hide_modal(socket, :delete_travel_period))
        period -> delete_travel_period(socket, period)
      end
    end)
  end

  defp show_delete_schedule(socket, schedule) do
    data = %{
      id: schedule.id,
      name: schedule.name,
      meeting_type_names: Schedules.meeting_type_names(schedule.id)
    }

    socket
    |> assign(:schedule_menu_open, false)
    |> ModalHook.show_modal(:delete_schedule, data)
  end

  # Finding the trip in the already-loaded list rather than fetching by id is
  # what scopes every action to this profile: an id belonging to someone else
  # is simply not in the list.
  defp with_travel_period(socket, id, fun) do
    case parse_id(id) do
      nil ->
        noreply(socket)

      period_id ->
        case Enum.find(socket.assigns.travel_periods, &(&1.id == period_id)) do
          nil -> noreply(socket)
          period -> fun.(period)
        end
    end
  end

  defp delete_schedule(socket, schedule) do
    case Schedules.delete(schedule) do
      {:ok, _schedule} ->
        Flash.info(dgettext("dashboard_availability", "Schedule deleted"))

        socket
        |> ModalHook.hide_modal(:delete_schedule)
        |> assign(:selected_schedule_id, nil)
        |> ScheduleSettingsComponent.load_schedules()
        |> ScheduleSettingsComponent.patch_to_selected()
        |> noreply()

      {:error, :cannot_delete_default} ->
        Flash.error(
          dgettext(
            "dashboard_availability",
            "Your default schedule cannot be deleted. Make another schedule the default first."
          )
        )

        noreply(ModalHook.hide_modal(socket, :delete_schedule))

      {:error, reason} ->
        Flash.error(ScheduleFailureMessage.for_reason(reason))
        noreply(socket)
    end
  end

  defp delete_travel_period(socket, period) do
    case Travel.delete_period(socket.assigns.profile, period) do
      {:ok, _deleted} ->
        Flash.info(dgettext("dashboard_availability", "Trip deleted"))

        socket
        |> ModalHook.hide_modal(:delete_travel_period)
        |> assign(:travel_periods, Travel.list_for_profile(socket.assigns.profile.id))
        |> noreply()

      {:error, reason} ->
        Flash.error(ScheduleFailureMessage.for_reason(reason))
        noreply(ModalHook.hide_modal(socket, :delete_travel_period))
    end
  end

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
