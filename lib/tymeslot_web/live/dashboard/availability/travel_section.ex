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
    <section class="space-y-4">
      <div class="flex items-center justify-between gap-4">
        <div>
          <h3 class="text-token-base font-semibold text-tymeslot-800">
            {dgettext("dashboard_availability", "Travel")}
          </h3>
          <p class="text-token-sm text-tymeslot-500">
            {dgettext(
              "dashboard_availability",
              "Dates when you are in another timezone, with the hours you are bookable there."
            )}
          </p>
        </div>

        <button
          type="button"
          class="btn btn-secondary shrink-0"
          phx-click="show_travel_form"
          phx-target={@myself}
        >
          {dgettext("dashboard_availability", "Add a trip")}
        </button>
      </div>

      <p :if={@periods == []} class="text-token-sm text-tymeslot-400">
        {dgettext("dashboard_availability", "No trips yet.")}
      </p>

      <ul :if={@periods != []} class="space-y-2">
        <li
          :for={period <- @periods}
          class="flex items-center justify-between gap-4 rounded-token-lg border-2 border-tymeslot-50 bg-white p-3"
        >
          <div class="min-w-0">
            <p class="truncate text-token-sm font-semibold text-tymeslot-800">{period.label}</p>
            <p class="text-token-xs text-tymeslot-500">
              {Calendar.strftime(period.start_date, "%d %b %Y")} – {Calendar.strftime(
                period.end_date,
                "%d %b %Y"
              )} · {period.timezone}
            </p>
            <%!-- A trip with no available weekday leaves the host silently
            unbookable for its whole span, so that state is called out here
            rather than only inside the edit form. --%>
            <p :if={no_bookable_hours?(period)} class="text-token-xs font-semibold text-red-600">
              {dgettext(
                "dashboard_availability",
                "No bookable hours set. You are unavailable for this trip's entire span."
              )}
            </p>
          </div>

          <div class="flex shrink-0 items-center gap-2">
            <button
              type="button"
              class="btn btn-ghost"
              phx-click="show_travel_form"
              phx-value-id={period.id}
              phx-target={@myself}
            >
              {dgettext("dashboard_availability", "Edit")}
            </button>
            <button
              type="button"
              class="btn btn-ghost"
              phx-click="show_delete_travel_modal"
              phx-value-id={period.id}
              phx-target={@myself}
            >
              {dgettext("dashboard_availability", "Delete")}
            </button>
          </div>
        </li>
      </ul>
    </section>
    """
  end

  defp no_bookable_hours?(%{days: days}) when is_list(days),
    do: not Enum.any?(days, & &1.is_available)

  defp no_bookable_hours?(_period), do: false
end
