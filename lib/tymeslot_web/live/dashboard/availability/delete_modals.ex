defmodule TymeslotWeb.Live.Dashboard.Availability.DeleteModals do
  @moduledoc """
  The two delete-confirmation modals on the availability page: a schedule
  and a travel period. Wrapped in one component so
  `TymeslotWeb.Dashboard.ScheduleSettingsComponent`'s own render names a
  single tag for both; the event handling behind them lives in
  `TymeslotWeb.Live.Dashboard.Availability.DeleteModalHandler`, the same
  split `TravelForm`/`TravelFormHandler` use for the trip editor.
  """
  use TymeslotWeb, :html

  alias TymeslotWeb.Components.Dashboard.Availability.{
    DeleteScheduleModal,
    DeleteTravelPeriodModal
  }

  attr :show_delete_schedule_modal, :boolean, required: true
  attr :delete_schedule_modal_data, :map, required: true
  attr :show_delete_travel_period_modal, :boolean, required: true
  attr :delete_travel_period_modal_data, :map, required: true
  attr :myself, :any, required: true

  @spec delete_modals(map()) :: Phoenix.LiveView.Rendered.t()
  def delete_modals(assigns) do
    ~H"""
    <DeleteScheduleModal.delete_schedule_modal
      id="delete-schedule-modal"
      show={@show_delete_schedule_modal}
      schedule_data={@delete_schedule_modal_data}
      on_cancel={JS.push("hide_delete_schedule_modal", target: @myself)}
      on_confirm={JS.push("confirm_delete_schedule", target: @myself)}
    />

    <DeleteTravelPeriodModal.delete_travel_period_modal
      id="delete-travel-period-modal"
      show={@show_delete_travel_period_modal}
      period_data={@delete_travel_period_modal_data}
      on_cancel={JS.push("hide_delete_travel_modal", target: @myself)}
      on_confirm={JS.push("confirm_delete_travel_period", target: @myself)}
    />
    """
  end
end
