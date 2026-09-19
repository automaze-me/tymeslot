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

  attr :submitted, :map,
    default: nil,
    doc: """
    The raw `phx-submit` params from the host's last, rejected attempt (an
    overlap, a bad day), if any. When set, every field below renders from
    this rather than from `:period`, so a validation error never comes back
    with what the host just typed erased. Cleared once a save succeeds.
    """

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
      |> assign(:values, form_values(assigns.submitted, assigns.period))
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
          value={@values.label}
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
            value={@values.start_date}
            required
            errors={FormValidationHelpers.field_errors(@form_errors, :start_date)}
          />

          <.input
            id="travel-end-date"
            name="end_date"
            type="date"
            label={dgettext("dashboard_availability", "End date")}
            value={@values.end_date}
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
                checked={day_checked?(@values, day_of_week)}
                class="checkbox w-5 h-5 rounded border-tymeslot-300 text-turquoise-600 focus:ring-turquoise-500"
              />
              {AvailabilityActions.day_name(day_of_week)}
            </label>

            <input
              type="time"
              name={"days[#{day_of_week}][start_time]"}
              value={day_field(@values, day_of_week, :start_time)}
              class="input"
            />
            <span class="text-tymeslot-400">–</span>
            <input
              type="time"
              name={"days[#{day_of_week}][end_time]"}
              value={day_field(@values, day_of_week, :end_time)}
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

  # `:submitted` wins whenever present: it is exactly what the host typed on
  # their last, rejected attempt, already in the string shape every field
  # below needs. Falling back to `:period` covers both a fresh edit (real
  # dates and times, formatted once here) and a fresh add (nothing to show).
  defp form_values(nil, nil) do
    %{label: nil, start_date: nil, end_date: nil, days: %{}}
  end

  defp form_values(nil, period) do
    %{
      label: period.label,
      start_date: Date.to_iso8601(period.start_date),
      end_date: Date.to_iso8601(period.end_date),
      days: days_from_period(period)
    }
  end

  defp form_values(submitted, _period) do
    %{
      label: submitted["label"],
      start_date: submitted["start_date"],
      end_date: submitted["end_date"],
      days: days_from_submitted(days_param(submitted["days"]))
    }
  end

  # A crafted submit can send `days` as something other than a map (or omit
  # it); either reads as "no days submitted" rather than raising below.
  defp days_param(days) when is_map(days), do: days
  defp days_param(_other), do: %{}

  defp days_from_period(period) do
    days = if is_list(period.days), do: period.days, else: []

    Map.new(days, fn day ->
      {day.day_of_week,
       %{
         is_available: day.is_available,
         start_time: format_time(day.start_time),
         end_time: format_time(day.end_time)
       }}
    end)
  end

  # Only the seven weekday keys a real submit can send, each with a map
  # value; anything else (a crafted `days[abc][...]` key, or a plain value
  # at `days[1]`) is dropped rather than raising `String.to_integer/1` or a
  # `Map` access error on a non-map value.
  defp days_from_submitted(days_params) do
    days_params
    |> Enum.flat_map(&submitted_day/1)
    |> Map.new()
  end

  defp submitted_day({key, attrs}) when is_map(attrs) do
    case weekday_key(key) do
      nil ->
        []

      day_of_week ->
        [
          {day_of_week,
           %{
             is_available: attrs["is_available"] in ["true", true],
             start_time: attrs["start_time"],
             end_time: attrs["end_time"]
           }}
        ]
    end
  end

  defp submitted_day(_not_a_map), do: []

  defp weekday_key(key) when is_binary(key) do
    case Integer.parse(key) do
      {day_of_week, ""} when day_of_week in 1..7 -> day_of_week
      _other -> nil
    end
  end

  defp weekday_key(_key), do: nil

  defp day_checked?(values, day_of_week) do
    case Map.get(values.days, day_of_week) do
      nil -> false
      day -> day.is_available
    end
  end

  defp day_field(values, day_of_week, field) do
    case Map.get(values.days, day_of_week) do
      nil -> nil
      day -> Map.get(day, field)
    end
  end

  defp format_time(nil), do: nil
  defp format_time(%Time{} = time), do: time |> Time.truncate(:second) |> Time.to_iso8601()
end
