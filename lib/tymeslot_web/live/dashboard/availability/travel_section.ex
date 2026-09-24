defmodule TymeslotWeb.Live.Dashboard.Availability.TravelSection do
  @moduledoc """
  Lists a profile's travel periods on the availability page.

  A trip is a date range with its own timezone and weekly hours, applying to
  every meeting type for the dates it covers. There is no cap on trips: the
  5-schedule cap exists because schedules render as a tab strip, and a list has
  no such constraint.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  attr :periods, :list, required: true
  attr :myself, :any, required: true

  @spec travel_section(map()) :: Phoenix.LiveView.Rendered.t()
  def travel_section(assigns) do
    ~H"""
    <div class="card-glass shadow-2xl shadow-tymeslot-200/50">
      <div class="flex flex-wrap items-start justify-between gap-4 mb-4">
        <.section_header
          level={2}
          icon="hero-globe-alt"
          title={dgettext("dashboard_availability", "Travel")}
        />

        <.action_button
          variant={:secondary}
          phx-click="show_travel_form"
          phx-target={@myself}
          data-testid="add-travel-period"
        >
          <.icon name="hero-plus" class="w-4 h-4" />
          {dgettext("dashboard_availability", "Add a trip")}
        </.action_button>
      </div>

      <p class="mb-8 text-token-sm text-tymeslot-500 font-bold">
        {dgettext(
          "dashboard_availability",
          "Dates when you are in another timezone, with the hours you are bookable there."
        )}
      </p>

      <.empty_state
        :if={@periods == []}
        message={dgettext("dashboard_availability", "No trips yet.")}
        secondary_message={
          dgettext(
            "dashboard_availability",
            "Add a trip and the days it covers are offered in that timezone, on the hours you keep there."
          )
        }
      >
        <:icon>
          <.icon name="hero-globe-alt" class="w-8 h-8 text-tymeslot-300" />
        </:icon>
      </.empty_state>

      <ul :if={@periods != []} class="space-y-3" data-testid="travel-list">
        <li
          :for={period <- @periods}
          class="flex flex-wrap items-center justify-between gap-3 rounded-token-xl border border-tymeslot-100 bg-tymeslot-50 px-4 py-3"
        >
          <div class="min-w-0">
            <p class="font-bold text-tymeslot-700">
              {Calendar.strftime(period.start_date, "%d %b %Y")} – {Calendar.strftime(
                period.end_date,
                "%d %b %Y"
              )}
            </p>
            <p class="truncate text-token-sm text-tymeslot-500 font-medium">
              {period.label} · {period.timezone}
            </p>
            <%!-- A trip with no available weekday leaves the host silently
            unbookable for its whole span, so that state is called out here
            rather than only inside the edit form. --%>
            <p :if={no_bookable_hours?(period)} class="text-token-sm font-bold text-red-600">
              {dgettext(
                "dashboard_availability",
                "No bookable hours set. You are unavailable for this trip's entire span."
              )}
            </p>
          </div>

          <div class="flex items-center gap-2 shrink-0">
            <button
              type="button"
              phx-click="show_travel_form"
              phx-value-id={period.id}
              phx-target={@myself}
              class="flex items-center justify-center h-9 w-9 bg-white text-tymeslot-700 rounded-token-lg border-2 border-tymeslot-100 hover:bg-tymeslot-100 transition-all shadow-sm shadow-tymeslot-500/5"
              aria-label={dgettext("dashboard_availability", "Edit trip")}
            >
              <.icon name="hero-pencil-square" class="w-5 h-5" />
            </button>
            <button
              type="button"
              phx-click="show_delete_travel_modal"
              phx-value-id={period.id}
              phx-target={@myself}
              class="flex items-center justify-center h-9 w-9 text-tymeslot-500 hover:text-red-500 hover:bg-red-50 rounded-token-lg border-2 border-transparent hover:border-red-100 transition-all"
              aria-label={dgettext("dashboard_availability", "Delete trip")}
            >
              <.icon name="hero-trash" class="w-5 h-5" />
            </button>
          </div>
        </li>
      </ul>
    </div>
    """
  end

  defp no_bookable_hours?(%{days: days}) when is_list(days),
    do: not Enum.any?(days, & &1.is_available)

  defp no_bookable_hours?(_period), do: false
end
