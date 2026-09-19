defmodule TymeslotWeb.Live.Dashboard.TravelSectionTest do
  use Tymeslot.DataCase, async: true

  @moduletag :availability
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias TymeslotWeb.Live.Dashboard.Availability.TravelSection

  describe "travel_section/1" do
    test "lists each trip with its label, dates and zone" do
      period =
        build(:travel_period,
          label: "Berlin, spring",
          start_date: ~D[2027-03-14],
          end_date: ~D[2027-03-28],
          timezone: "Europe/Berlin"
        )

      html =
        render_component(&TravelSection.travel_section/1, periods: [period], myself: nil)

      assert html =~ "Berlin, spring"
      assert html =~ "Europe/Berlin"
    end

    test "shows an empty state when there are no trips" do
      html = render_component(&TravelSection.travel_section/1, periods: [], myself: nil)

      assert html =~ "No trips"
    end
  end
end
