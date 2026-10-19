defmodule Tymeslot.Factory.Fork do
  @moduledoc """
  Factories for this fork's own schemas (travel periods, booking pages),
  injected into `Tymeslot.Factory` with `use`, so that upstream's factory
  module stays as upstream ships it.
  """

  defmacro __using__(_opts) do
    quote do
      alias Tymeslot.Availability.TravelPeriodDaySchema
      alias Tymeslot.Availability.TravelPeriodSchema
      alias Tymeslot.BookingPages.BookingPageMeetingTypeSchema
      alias Tymeslot.BookingPages.BookingPageSchema

      @spec travel_period_factory() :: Tymeslot.Availability.TravelPeriodSchema.t()
      def travel_period_factory do
        %TravelPeriodSchema{
          label: sequence(:travel_period_label, &"Trip #{&1}"),
          start_date: Date.add(Date.utc_today(), 30),
          end_date: Date.add(Date.utc_today(), 44),
          timezone: "Europe/Berlin",
          profile: build(:profile)
        }
      end

      @spec travel_period_day_factory() :: Tymeslot.Availability.TravelPeriodDaySchema.t()
      def travel_period_day_factory do
        %TravelPeriodDaySchema{
          # Wednesday
          day_of_week: 3,
          is_available: true,
          start_time: ~T[10:00:00],
          end_time: ~T[16:00:00],
          travel_period: build(:travel_period)
        }
      end

      @spec booking_page_factory() :: Tymeslot.BookingPages.BookingPageSchema.t()
      def booking_page_factory do
        %BookingPageSchema{
          name: sequence(:booking_page_name, &"Page #{&1}"),
          slug: sequence(:booking_page_slug, &"page-#{&1}"),
          booking_theme: "1",
          profile: build(:profile)
        }
      end

      @spec booking_page_meeting_type_factory() :: BookingPageMeetingTypeSchema.t()
      def booking_page_meeting_type_factory do
        %BookingPageMeetingTypeSchema{
          booking_page: build(:booking_page),
          meeting_type: build(:meeting_type)
        }
      end
    end
  end
end
