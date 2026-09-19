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
  alias TymeslotWeb.Components.CoreComponents

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
    <CoreComponents.modal id={@id} show={@show} on_cancel={@on_cancel} size={:medium}>
      <:header>
        <div class="flex items-center gap-2">
          <svg class="w-5 h-5 text-red-500" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-2.5L13.732 4c-.77-.833-1.964-.833-2.732 0L3.732 16.5c-.77.833.192 2.5 1.732 2.5z"
            />
          </svg>
          {dgettext("dashboard_availability", "Delete Trip")}
        </div>
      </:header>

      <%= if @period_data do %>
        <div class="space-y-4">
          <%!-- phx-no-format: the HTML plugin collapses the trailing keyword
          argument onto the message line and the Elixir formatter splits it
          back out again, so the two never agree on this call. --%>
          <p class="text-tymeslot-600 font-medium text-lg leading-relaxed" phx-no-format>
            {dgettext(
              "dashboard_availability",
              "Are you sure you want to delete %{name}?",
              name: @period_data.label
            )}
          </p>
          <p class="text-tymeslot-500 font-medium">
            {dgettext("dashboard_availability", "This action cannot be undone.")}
          </p>
        </div>
      <% end %>

      <:footer>
        <div class="flex justify-end gap-3">
          <CoreComponents.action_button variant={:secondary} phx-click={@on_cancel}>
            {dgettext("dashboard_availability", "Cancel")}
          </CoreComponents.action_button>
          <CoreComponents.action_button variant={:danger} phx-click={@on_confirm}>
            {dgettext("dashboard_availability", "Delete Trip")}
          </CoreComponents.action_button>
        </div>
      </:footer>
    </CoreComponents.modal>
    """
  end
end
