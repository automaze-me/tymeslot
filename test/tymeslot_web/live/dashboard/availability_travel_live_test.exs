defmodule TymeslotWeb.Dashboard.AvailabilityTravelLiveTest do
  @moduledoc """
  End-to-end coverage for the Travel section of the availability page: the
  trip list, and the add/edit form wired in Task 12.

  Split out of `AvailabilityLiveTest` (rather than folded in there) purely to
  keep each test module a reasonable size — the travel surface is large
  enough, and independent enough of the weekly schedule editor, to stand on
  its own.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :availability
  @moduletag :live

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Availability.Travel
  alias Tymeslot.Infrastructure.AvailabilityCache

  setup %{conn: conn} do
    AvailabilityCache.clear_all()
    {:ok, ctx} = setup_dashboard_user(%{conn: conn})
    ctx
  end

  # The travel form's zone picker is `TimezoneDropdown`: a hidden field that
  # LiveViewTest (rightly) refuses to override directly, since no real user
  # can type into it. Selecting a zone means clicking through the dropdown
  # the same way a host would.
  defp select_travel_timezone(view, timezone) do
    view
    |> element("[phx-click='toggle_timezone_dropdown']")
    |> render_click()

    view
    |> element("[phx-click='change_timezone'][phx-value-timezone='#{timezone}']")
    |> render_click()
  end

  describe "the travel section" do
    test "lists a trip with its label, dates and zone", %{conn: conn, profile: profile} do
      insert(:travel_period,
        profile: profile,
        label: "Lisbon retreat",
        start_date: ~D[2027-05-01],
        end_date: ~D[2027-05-10],
        timezone: "Europe/Lisbon"
      )

      {:ok, _view, html} = live(conn, ~p"/dashboard/availability")

      assert html =~ "Lisbon retreat"
      assert html =~ "Europe/Lisbon"
    end

    test "shows the empty state when there are no trips", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/availability")

      assert html =~ "No trips yet."
    end

    test "deletes a trip via the confirmation modal", %{conn: conn, profile: profile} do
      period =
        insert(:travel_period,
          profile: profile,
          label: "Lisbon retreat",
          start_date: ~D[2027-05-01],
          end_date: ~D[2027-05-10],
          timezone: "Europe/Lisbon"
        )

      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      view
      |> element("button[phx-click='show_delete_travel_modal'][phx-value-id='#{period.id}']")
      |> render_click()

      html = render(view)
      assert html =~ "Lisbon retreat"

      view
      |> element("#delete-travel-period-modal button", "Delete Trip")
      |> render_click()

      assert render(view) =~ "Trip deleted"
      refute Enum.any?(Travel.list_for_profile(profile.id), &(&1.id == period.id))
    end

    test "opens the add-trip form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      html =
        view
        |> element("button[phx-click='show_travel_form']", "Add a trip")
        |> render_click()

      assert html =~ "New trip"
      assert has_element?(view, "#travel-form-modal form input[name='label']")
    end

    test "opens the edit-trip form pre-filled with the trip's data", %{
      conn: conn,
      profile: profile
    } do
      period =
        insert(:travel_period,
          profile: profile,
          label: "Lisbon retreat",
          start_date: ~D[2027-05-01],
          end_date: ~D[2027-05-10],
          timezone: "Europe/Lisbon"
        )

      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      html =
        view
        |> element("button[phx-click='show_travel_form'][phx-value-id='#{period.id}']")
        |> render_click()

      assert html =~ "Edit trip"
      assert html =~ "Lisbon retreat"
      assert html =~ "2027-05-01"
      assert html =~ "2027-05-10"
    end

    test "creates a trip end to end", %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      view
      |> element("button[phx-click='show_travel_form']", "Add a trip")
      |> render_click()

      select_travel_timezone(view, "Europe/Madrid")

      view
      |> form("#travel-form-modal form", %{
        "label" => "Ibiza retreat",
        "start_date" => "2027-06-01",
        "end_date" => "2027-06-14"
      })
      |> render_submit()

      assert [period] = Travel.list_for_profile(profile.id)
      assert period.label == "Ibiza retreat"
      assert period.start_date == ~D[2027-06-01]
      assert period.end_date == ~D[2027-06-14]
      assert period.timezone == "Europe/Madrid"
    end

    test "updates an existing trip end to end", %{conn: conn, profile: profile} do
      period =
        insert(:travel_period,
          profile: profile,
          label: "Lisbon retreat",
          start_date: ~D[2027-05-01],
          end_date: ~D[2027-05-10],
          timezone: "Europe/Lisbon"
        )

      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      view
      |> element("button[phx-click='show_travel_form'][phx-value-id='#{period.id}']")
      |> render_click()

      view
      |> form("#travel-form-modal form", %{
        "label" => "Lisbon retreat, extended",
        "start_date" => "2027-05-01",
        "end_date" => "2027-05-20",
        "timezone" => "Europe/Lisbon"
      })
      |> render_submit()

      assert [updated] = Travel.list_for_profile(profile.id)
      assert updated.id == period.id
      assert updated.label == "Lisbon retreat, extended"
      assert updated.end_date == ~D[2027-05-20]
    end

    test "saves weekly bookable hours for a trip", %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      view
      |> element("button[phx-click='show_travel_form']", "Add a trip")
      |> render_click()

      select_travel_timezone(view, "Europe/Berlin")

      view
      |> form("#travel-form-modal form", %{
        "label" => "Berlin sprint",
        "start_date" => "2027-07-01",
        "end_date" => "2027-07-14",
        "days" => %{
          "1" => %{"is_available" => "true", "start_time" => "10:00", "end_time" => "16:00"},
          "2" => %{"is_available" => "false"},
          "3" => %{"is_available" => "false"},
          "4" => %{"is_available" => "false"},
          "5" => %{"is_available" => "false"},
          "6" => %{"is_available" => "false"},
          "7" => %{"is_available" => "false"}
        }
      })
      |> render_submit()

      assert [period] = Travel.list_for_profile(profile.id)
      monday = Enum.find(period.days, &(&1.day_of_week == 1))

      assert monday.is_available == true
      assert monday.start_time == ~T[10:00:00]
      assert monday.end_time == ~T[16:00:00]
      refute Enum.any?(period.days, &(&1.day_of_week != 1 and &1.is_available))
    end

    test "shows the overlap error instead of creating a conflicting trip", %{
      conn: conn,
      profile: profile
    } do
      insert(:travel_period,
        profile: profile,
        label: "Existing trip",
        start_date: ~D[2027-08-01],
        end_date: ~D[2027-08-15],
        timezone: "Europe/Berlin"
      )

      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      view
      |> element("button[phx-click='show_travel_form']", "Add a trip")
      |> render_click()

      select_travel_timezone(view, "Europe/Berlin")

      html =
        view
        |> form("#travel-form-modal form", %{
          "label" => "Overlapping trip",
          "start_date" => "2027-08-10",
          "end_date" => "2027-08-20"
        })
        |> render_submit()

      assert html =~ "overlaps an existing trip"
      assert length(Travel.list_for_profile(profile.id)) == 1
      assert Process.alive?(view.pid)
    end

    test "warns on the trip list when a trip has no bookable hours", %{
      conn: conn,
      profile: profile
    } do
      insert(:travel_period,
        profile: profile,
        label: "Silent trip",
        start_date: ~D[2027-09-01],
        end_date: ~D[2027-09-10],
        timezone: "Europe/Berlin"
      )

      {:ok, _view, html} = live(conn, ~p"/dashboard/availability")

      assert html =~ "Silent trip"
      assert html =~ "No bookable hours set"
    end

    test "does not warn once a trip has at least one bookable day", %{
      conn: conn,
      profile: profile
    } do
      period =
        insert(:travel_period,
          profile: profile,
          label: "Bookable trip",
          start_date: ~D[2027-09-15],
          end_date: ~D[2027-09-20],
          timezone: "Europe/Berlin"
        )

      insert(:travel_period_day,
        travel_period: period,
        day_of_week: 1,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )

      {:ok, _view, html} = live(conn, ~p"/dashboard/availability")

      assert html =~ "Bookable trip"
      refute html =~ "No bookable hours set"
    end
  end
end
