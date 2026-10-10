defmodule TymeslotWeb.Components.Dashboard.Availability.DeleteTravelPeriodModal do
  @moduledoc """
  Modal component for confirming the deletion of a travel period.

  A trip is real configuration — it can shift a host's timezone and hours for
  every meeting type during its dates — so deletion is confirmed the same way
  deleting a schedule is, rather than firing straight off a list button.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Components.CoreComponents.Modal

  @doc """
  Renders a delete trip confirmation modal.

  ## Attributes

    * `id` - The modal ID (required)
    * `show` - Boolean to show/hide the modal (required)
    * `period_data` - Map containing the trip's `id` and `label` (required)
    * `on_cancel` - JS command to execute when canceling (required)
    * `on_confirm` - JS command to execute when confirming deletion (required)

  ## Examples

      <DeleteTravelPeriodModal.delete_travel_period_modal
        id="delete-travel-period-modal"
        show={@show_delete_travel_period_modal}
        period_data={@delete_travel_period_modal_data}
        on_cancel={JS.push("hide_delete_travel_modal", target: @myself)}
        on_confirm={JS.push("confirm_delete_travel_period", target: @myself)}
      />
  """
  attr :id, :string, required: true
  attr :show, :boolean, required: true
  attr :period_data, :map, required: true
  attr :on_cancel, JS, required: true
  attr :on_confirm, JS, required: true

  @spec delete_travel_period_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def delete_travel_period_modal(assigns) do
    ~H"""
    <Modal.confirm_modal
      id={@id}
      show={@show}
      title={dgettext("dashboard_availability", "Delete trip")}
      confirm_label={dgettext("dashboard_availability", "Delete Trip")}
      on_cancel={@on_cancel}
      on_confirm={@on_confirm}
    >
      <%= if @period_data do %>
        <%!-- phx-no-format: the HTML plugin collapses the trailing keyword
        argument onto the message line and the Elixir formatter splits it
        back out again, so the two never agree on this call. --%>
        <p phx-no-format>
          {dgettext(
            "dashboard_availability",
            "Are you sure you want to delete %{name}?",
            name: @period_data.label
          )}
        </p>
        <p class="text-tymeslot-500">
          {dgettext("dashboard_availability", "This action cannot be undone.")}
        </p>
      <% end %>
    </Modal.confirm_modal>
    """
  end
end
