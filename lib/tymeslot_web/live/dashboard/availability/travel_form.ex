defmodule TymeslotWeb.Live.Dashboard.Availability.TravelForm do
  @moduledoc """
  Create and edit a travel period: label, inclusive date range, timezone, and
  one bookable-hours row per weekday.

  The weekday rows are a small dedicated grid rather than a reuse of
  `TymeslotWeb.Dashboard.Availability.DayCardComponent`. That component saves
  each weekday immediately against a *schedule* via `AvailabilityActions`,
  carries breaks (a stated non-goal for a trip), and drives a per-day overflow
  menu — all wired to `ListComponent`'s own event names. `TravelPeriodDaySchema`
  deliberately mirrors `WeeklyAvailabilitySchema` in shape, but the two
  editors' interaction models differ enough (submit-together here, save-per-
  click there) that reusing the schedule grid would mean changing its
  behaviour for the ordinary weekly editor. A dedicated grid, submitted with
  the rest of the form and persisted one weekday at a time via
  `Travel.set_day/3`, is the smaller and safer surface.

  The zone picker reuses `TymeslotWeb.Components.TimezoneDropdown`, the same
  component the profile settings page uses, rather than a plain HTML select.
  It is a function component, so all of its state (which trip is being
  edited, the pending zone selection, the dropdown's open/search state) lives
  in the parent live component; this module only renders.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Availability.{AvailabilityActions, TravelPeriodSchema}
  alias TymeslotWeb.Components.TimezoneDropdown
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  @weekdays 1..7

  attr :id, :string, required: true
  attr :show, :boolean, required: true
  attr :period, :map, default: nil
  attr :timezone_options, :list, required: true
  attr :timezone, :string, default: nil
  attr :timezone_dropdown_open, :boolean, default: false
  attr :timezone_search, :string, default: ""
  attr :form_errors, :map, default: %{}
  attr :myself, :any, required: true
  attr :on_cancel, :any, required: true

  @spec travel_form_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def travel_form_modal(assigns) do
    assigns =
      assigns
      |> assign(:weekdays, @weekdays)
      |> assign(:zone_profile, %{timezone: assigns.timezone})
      |> assign(
        :timezone_error,
        List.first(FormValidationHelpers.field_errors(assigns.form_errors, :timezone))
      )

    ~H"""
    <.modal id={@id} show={@show} on_cancel={@on_cancel} size={:large}>
      <:header>{header_title(@period)}</:header>

      <form phx-submit="save_travel_period" phx-target={@myself} class="space-y-5">
        <input type="hidden" name="timezone" value={@timezone} />

        <.input
          id="travel-label"
          name="label"
          type="text"
          label={dgettext("dashboard_availability", "Label")}
          value={@period && @period.label}
          maxlength={TravelPeriodSchema.label_max_length()}
          required
          errors={FormValidationHelpers.field_errors(@form_errors, :label)}
        />

        <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <.input
            id="travel-start-date"
            name="start_date"
            type="date"
            label={dgettext("dashboard_availability", "Start date")}
            value={@period && Date.to_iso8601(@period.start_date)}
            required
            errors={FormValidationHelpers.field_errors(@form_errors, :start_date)}
          />

          <.input
            id="travel-end-date"
            name="end_date"
            type="date"
            label={dgettext("dashboard_availability", "End date")}
            value={@period && Date.to_iso8601(@period.end_date)}
            required
            errors={FormValidationHelpers.field_errors(@form_errors, :end_date)}
          />
        </div>

        <div>
          <TimezoneDropdown.timezone_dropdown
            profile={@zone_profile}
            timezone_options={@timezone_options}
            timezone_dropdown_open={@timezone_dropdown_open}
            timezone_search={@timezone_search}
            target={@myself}
            safe_flags={false}
          />
          <p :if={@timezone_error} class="text-token-xs text-red-600">{@timezone_error}</p>
        </div>

        <fieldset class="space-y-2">
          <legend class="text-token-sm font-semibold text-tymeslot-700">
            {dgettext("dashboard_availability", "Bookable hours during this trip")}
          </legend>

          <div :for={day_of_week <- @weekdays} class="flex flex-wrap items-center gap-3">
            <label class="flex w-32 shrink-0 items-center gap-2 text-token-sm text-tymeslot-700">
              <input
                type="hidden"
                name={"days[#{day_of_week}][is_available]"}
                value="false"
              />
              <input
                type="checkbox"
                name={"days[#{day_of_week}][is_available]"}
                value="true"
                checked={day_available?(@period, day_of_week)}
                class="checkbox w-5 h-5 rounded border-tymeslot-300 text-turquoise-600 focus:ring-turquoise-500"
              />
              {AvailabilityActions.day_name(day_of_week)}
            </label>

            <input
              type="time"
              name={"days[#{day_of_week}][start_time]"}
              value={day_time(@period, day_of_week, :start_time)}
              class="input"
            />
            <span class="text-tymeslot-400">–</span>
            <input
              type="time"
              name={"days[#{day_of_week}][end_time]"}
              value={day_time(@period, day_of_week, :end_time)}
              class="input"
            />
          </div>
        </fieldset>

        <div class="flex justify-end gap-2">
          <button type="button" class="btn btn-ghost" phx-click={@on_cancel}>
            {dgettext("dashboard_availability", "Cancel")}
          </button>
          <button type="submit" class="btn btn-primary">
            {dgettext("dashboard_availability", "Save")}
          </button>
        </div>
      </form>
    </.modal>
    """
  end

  defp header_title(nil), do: dgettext("dashboard_availability", "New trip")
  defp header_title(_period), do: dgettext("dashboard_availability", "Edit trip")

  defp day_available?(nil, _day_of_week), do: false

  defp day_available?(period, day_of_week) do
    case find_day(period, day_of_week) do
      nil -> false
      day -> day.is_available
    end
  end

  defp day_time(nil, _day_of_week, _field), do: nil

  defp day_time(period, day_of_week, field) do
    case find_day(period, day_of_week) do
      nil -> nil
      day -> day |> Map.get(field) |> format_time()
    end
  end

  defp find_day(period, day_of_week) do
    days = if is_list(period.days), do: period.days, else: []
    Enum.find(days, &(&1.day_of_week == day_of_week))
  end

  defp format_time(nil), do: nil
  defp format_time(%Time{} = time), do: time |> Time.truncate(:second) |> Time.to_iso8601()
end
