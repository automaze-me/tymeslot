defmodule TymeslotWeb.Live.Dashboard.TravelFormTest do
  use Tymeslot.DataCase, async: true

  @moduletag :availability
  @moduletag :live
  @moduletag :components

  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias Tymeslot.Availability.Travel
  alias TymeslotWeb.Live.Dashboard.Availability.TravelForm

  defp assigns(overrides) do
    Map.merge(
      %{
        id: "travel-form",
        show: true,
        period: nil,
        timezone_options: [{"Europe/Berlin", "Europe/Berlin"}],
        timezone: "Europe/Berlin",
        timezone_dropdown_open: false,
        timezone_search: "",
        form_errors: %{},
        myself: nil,
        on_cancel: %Phoenix.LiveView.JS{}
      },
      overrides
    )
  end

  describe "travel_form_modal/1" do
    test "renders empty date and label fields for a new trip" do
      html = render_component(&TravelForm.travel_form_modal/1, assigns(%{}))

      assert html =~ ~s(name="label")
      assert html =~ ~s(name="start_date")
      assert html =~ ~s(name="end_date")
      assert html =~ ~s(name="timezone")
      assert html =~ "New trip"
    end

    test "prefills the fields when editing an existing trip" do
      period =
        build(:travel_period,
          label: "Berlin, spring",
          start_date: ~D[2027-03-14],
          end_date: ~D[2027-03-28],
          timezone: "Europe/Berlin"
        )

      html = render_component(&TravelForm.travel_form_modal/1, assigns(%{period: period}))

      assert html =~ "Berlin, spring"
      assert html =~ "2027-03-14"
      assert html =~ "2027-03-28"
      assert html =~ "Edit trip"
    end

    test "prefills a weekday's hours when editing a trip that already has them" do
      period =
        insert(:travel_period, timezone: "Europe/Berlin")

      insert(:travel_period_day,
        travel_period: period,
        day_of_week: 2,
        is_available: true,
        start_time: ~T[09:30:00],
        end_time: ~T[14:00:00]
      )

      period = hd(Travel.list_for_profile(period.profile_id))

      html = render_component(&TravelForm.travel_form_modal/1, assigns(%{period: period}))

      assert html =~ ~s(name="days[2][is_available]" value="true" checked)
      assert html =~ "09:30:00"
      assert html =~ "14:00:00"
    end

    test "renders a row per weekday" do
      html = render_component(&TravelForm.travel_form_modal/1, assigns(%{}))

      for day_of_week <- 1..7 do
        assert html =~ ~s(name="days[#{day_of_week}][is_available]")
      end
    end

    test "shows a field error" do
      html =
        render_component(
          &TravelForm.travel_form_modal/1,
          assigns(%{form_errors: %{start_date: "overlaps an existing trip"}})
        )

      assert html =~ "overlaps an existing trip"
    end
  end
end
