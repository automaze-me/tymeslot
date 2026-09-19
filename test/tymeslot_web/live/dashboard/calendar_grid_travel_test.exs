defmodule TymeslotWeb.Live.Dashboard.CalendarGridTravelTest do
  use Tymeslot.DataCase, async: true

  @moduletag :availability
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias Tymeslot.Availability.Travel
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers.DataLoading
  alias TymeslotWeb.Dashboard.CalendarGrid.Views.StatusBanners

  describe "the grid's zone" do
    test "is the trip zone while a trip covers today" do
      profile = insert(:profile, timezone: "America/New_York")
      today = Date.utc_today()

      {:ok, _trip} =
        Travel.create_period(profile, %{
          label: "Berlin now",
          start_date: Date.add(today, -1),
          end_date: Date.add(today, 5),
          timezone: "Europe/Berlin"
        })

      assert Travel.timezone_on(profile, today) == "Europe/Berlin"
    end

    test "is the home zone when no trip covers today" do
      profile = insert(:profile, timezone: "America/New_York")
      today = Date.utc_today()

      {:ok, _trip} =
        Travel.create_period(profile, %{
          label: "Berlin later",
          start_date: Date.add(today, 30),
          end_date: Date.add(today, 44),
          timezone: "Europe/Berlin"
        })

      assert Travel.timezone_on(profile, today) == "America/New_York"
    end
  end

  # ---------------------------------------------------------------------------
  # DataLoading.assign_timezone/1 — this is the function the dashboard grid
  # actually calls. The describe block above only re-proves Task 8's resolver;
  # these tests prove the grid's own assign wiring reacts to it.
  # ---------------------------------------------------------------------------

  describe "DataLoading.assign_timezone/1" do
    defp build_socket(profile) do
      %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          profile: profile,
          current_user: %{id: profile && Map.get(profile, :user_id)}
        }
      }
    end

    test "uses the trip's zone and assigns the active trip while it covers today" do
      profile = insert(:profile, timezone: "America/New_York")
      today = Date.utc_today()

      {:ok, trip} =
        Travel.create_period(profile, %{
          label: "Berlin now",
          start_date: Date.add(today, -1),
          end_date: Date.add(today, 5),
          timezone: "Europe/Berlin"
        })

      result = DataLoading.assign_timezone(build_socket(profile))

      assert result.assigns.user_timezone == "Europe/Berlin"

      assert %{id: id, timezone: "Europe/Berlin", label: "Berlin now"} =
               result.assigns.active_travel_period

      assert id == trip.id
    end

    test "keeps the home zone and a nil active trip when no trip covers today" do
      profile = insert(:profile, timezone: "America/New_York")
      today = Date.utc_today()

      {:ok, _trip} =
        Travel.create_period(profile, %{
          label: "Berlin later",
          start_date: Date.add(today, 30),
          end_date: Date.add(today, 44),
          timezone: "Europe/Berlin"
        })

      result = DataLoading.assign_timezone(build_socket(profile))

      assert result.assigns.user_timezone == "America/New_York"
      assert result.assigns.active_travel_period == nil
    end

    test "does not raise when the socket carries no usable profile" do
      assert %{active_travel_period: nil} = DataLoading.assign_timezone(build_socket(nil)).assigns
      assert %{active_travel_period: nil} = DataLoading.assign_timezone(build_socket(%{})).assigns
    end
  end

  # ---------------------------------------------------------------------------
  # StatusBanners.status_banners/1 — the active-trip banner must actually be
  # reachable from the render tree, not just exist as a dead function.
  # ---------------------------------------------------------------------------

  describe "StatusBanners.status_banners/1 active-trip banner" do
    defp banner_assigns(active_trip) do
      %{
        stale_integrations: [],
        syncing: false,
        sync_total: 0,
        sync_completed: 0,
        oldest_sync_at: nil,
        myself: nil,
        active_trip: active_trip
      }
    end

    test "names the trip's zone and label while a trip covers today" do
      trip = insert(:travel_period, timezone: "Europe/Berlin", label: "Berlin now")

      html = render_component(&StatusBanners.status_banners/1, banner_assigns(trip))

      assert html =~ "Europe/Berlin"
      assert html =~ "Berlin now"
    end

    test "renders nothing about travel when no trip covers today" do
      html = render_component(&StatusBanners.status_banners/1, banner_assigns(nil))

      refute html =~ "hero-globe-europe-africa"
    end
  end
end
