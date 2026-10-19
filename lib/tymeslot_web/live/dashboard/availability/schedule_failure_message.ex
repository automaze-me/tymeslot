defmodule TymeslotWeb.Live.Dashboard.Availability.ScheduleFailureMessage do
  @moduledoc """
  Turns a `Schedules` or `Travel` write's failure reason into the text a host
  sees in a flash message.

  Shared between `TymeslotWeb.Dashboard.ScheduleSettingsComponent` and
  `TymeslotWeb.Live.Dashboard.Availability.DeleteModalHandler`: both call
  into these contexts and both need the same mapping from a failure reason
  to user-facing text, so it lives here once rather than as two copies that
  could drift apart.
  """
  use Gettext, backend: TymeslotWeb.Gettext

  alias Ecto.Changeset
  alias Tymeslot.Availability.Schedules
  alias TymeslotWeb.Helpers.FormErrors

  @spec for_reason(Changeset.t() | atom() | String.t()) :: String.t()
  def for_reason(%Changeset{} = changeset),
    do: FormErrors.first(changeset, %{name: dgettext("dashboard_availability", "Schedule name")})

  def for_reason(message) when is_binary(message), do: message

  def for_reason(:schedule_limit_reached) do
    dgettext(
      "dashboard_availability",
      "You have reached the limit of %{count} schedules. Delete one to add another.",
      count: Schedules.max_schedules()
    )
  end

  def for_reason(_reason),
    do: dgettext("dashboard_availability", "Something went wrong. Please try again.")
end
