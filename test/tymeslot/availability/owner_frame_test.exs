defmodule Tymeslot.Availability.OwnerFrameTest do
  use Tymeslot.DataCase, async: true

  @moduletag :availability
  @moduletag :unit

  import Tymeslot.Factory

  alias Tymeslot.Availability.OwnerFrame

  @home "America/New_York"

  defp trip(start_date, end_date, timezone, days) do
    %{
      start_date: start_date,
      end_date: end_date,
      timezone: timezone,
      days: days
    }
  end

  defp day(day_of_week, start_time, end_time) do
    %{
      day_of_week: day_of_week,
      is_available: true,
      start_time: start_time,
      end_time: end_time
    }
  end

  describe "for_date/3 with no trips" do
    test "returns the home zone and no day when the config carries an empty list" do
      frame = OwnerFrame.for_date(~D[2027-03-17], @home, %{travel_periods: []})

      assert frame == %{timezone: @home, day: nil, source: :schedule}
    end

    test "returns the home zone when the config carries no trip key at all" do
      frame = OwnerFrame.for_date(~D[2027-03-17], @home, %{})

      assert frame.timezone == @home
      assert frame.day == nil
      assert frame.source == :schedule
    end

    test "returns the home zone for a date outside every trip" do
      periods = [
        trip(~D[2027-03-14], ~D[2027-03-28], "Europe/Berlin", [day(3, ~T[10:00:00], ~T[16:00:00])])
      ]

      frame = OwnerFrame.for_date(~D[2027-04-07], @home, %{travel_periods: periods})

      assert frame.timezone == @home
      assert frame.source == :schedule
    end
  end

  describe "for_date/3 inside a trip" do
    test "returns the trip zone and that weekday's hours" do
      periods = [
        trip(~D[2027-03-14], ~D[2027-03-28], "Europe/Berlin", [day(3, ~T[10:00:00], ~T[16:00:00])])
      ]

      # 2027-03-17 is a Wednesday.
      frame = OwnerFrame.for_date(~D[2027-03-17], @home, %{travel_periods: periods})

      assert frame.timezone == "Europe/Berlin"
      assert frame.source == :travel
      assert frame.day.is_available
      assert frame.day.start_time == ~T[10:00:00]
      assert frame.day.end_time == ~T[16:00:00]
      assert frame.day.day_of_week == 3
      assert frame.day.breaks == []
    end

    test "reports a weekday the trip does not define as unavailable" do
      periods = [
        trip(~D[2027-03-14], ~D[2027-03-28], "Europe/Berlin", [day(3, ~T[10:00:00], ~T[16:00:00])])
      ]

      # 2027-03-18 is a Thursday, which this trip leaves undefined.
      frame = OwnerFrame.for_date(~D[2027-03-18], @home, %{travel_periods: periods})

      assert frame.timezone == "Europe/Berlin"
      refute frame.day.is_available
      assert frame.day.start_time == nil
    end

    test "includes both inclusive boundary dates" do
      periods = [trip(~D[2027-03-14], ~D[2027-03-28], "Europe/Berlin", [])]
      config = %{travel_periods: periods}

      assert OwnerFrame.for_date(~D[2027-03-14], @home, config).source == :travel
      assert OwnerFrame.for_date(~D[2027-03-28], @home, config).source == :travel
      assert OwnerFrame.for_date(~D[2027-03-13], @home, config).source == :schedule
      assert OwnerFrame.for_date(~D[2027-03-29], @home, config).source == :schedule
    end

    test "fails closed when a trip's days did not load" do
      periods = [
        %{
          start_date: ~D[2027-03-14],
          end_date: ~D[2027-03-28],
          timezone: "Europe/Berlin",
          days: %Ecto.Association.NotLoaded{}
        }
      ]

      frame = OwnerFrame.for_date(~D[2027-03-17], @home, %{travel_periods: periods})

      # Offering nothing is the safe direction: the alternative would be home
      # hours applied in a foreign zone.
      assert frame.timezone == "Europe/Berlin"
      refute frame.day.is_available
    end
  end

  describe "for_date/3 falling back to a query" do
    test "reads trips from the database when the config carries only a profile id" do
      profile = insert(:profile)

      period =
        insert(:travel_period,
          profile: profile,
          start_date: ~D[2027-03-14],
          end_date: ~D[2027-03-28],
          timezone: "Europe/Berlin"
        )

      insert(:travel_period_day,
        travel_period: period,
        day_of_week: 3,
        is_available: true,
        start_time: ~T[10:00:00],
        end_time: ~T[16:00:00]
      )

      frame = OwnerFrame.for_date(~D[2027-03-17], @home, %{profile_id: profile.id})

      assert frame.timezone == "Europe/Berlin"
      assert frame.day.start_time == ~T[10:00:00]
    end

    test "prefers a prefetched list over querying" do
      profile = insert(:profile)

      insert(:travel_period,
        profile: profile,
        start_date: ~D[2027-03-14],
        end_date: ~D[2027-03-28],
        timezone: "Europe/Berlin"
      )

      # An explicit empty list means "no trips in this window", and must not be
      # second-guessed by a query.
      frame =
        OwnerFrame.for_date(~D[2027-03-17], @home, %{
          profile_id: profile.id,
          travel_periods: []
        })

      assert frame.timezone == @home
      assert frame.source == :schedule
    end
  end
end
