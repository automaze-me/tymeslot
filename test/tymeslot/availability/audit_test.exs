defmodule Tymeslot.Availability.AuditTest do
  use Tymeslot.DataCase, async: true

  @moduletag :availability

  import ExUnit.CaptureIO

  alias Tymeslot.Availability.Audit
  alias Tymeslot.Availability.Travel

  defp setup_bookable_profile(username) do
    user = insert(:user)
    profile = insert(:profile, user: user, username: username, timezone: "Etc/UTC")
    schedule = insert(:availability_schedule, profile: profile, is_default: true)

    Enum.each(1..7, fn day_of_week ->
      insert(:weekly_availability,
        schedule: schedule,
        day_of_week: day_of_week,
        is_available: day_of_week in 1..5,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )
    end)

    profile
  end

  # Pick a Monday far enough in the future that min_advance_hours doesn't
  # eat into it, and within the default 90-day advance booking window.
  defp future_monday do
    today = Date.utc_today()
    offset = rem(8 - Date.day_of_week(today), 7)
    offset = if offset == 0, do: 7, else: offset
    Date.add(today, offset)
  end

  describe "run/2" do
    test "returns {:error, :not_found} for an unknown username" do
      assert {:error, :not_found} = Audit.run("nonexistent-#{System.unique_integer()}")
    end

    test "returns {:ok, result} and prints a report for an existing profile" do
      username = "audit-run-#{System.unique_integer([:positive])}"
      profile = setup_bookable_profile(username)
      monday = future_monday()

      output =
        capture_io(fn ->
          assert {:ok, result} =
                   Audit.run(username, start_date: monday, horizon_days: 7)

          assert result.profile_id == profile.id
          assert result.username == username
          assert result.horizon == {monday, Date.add(monday, 7)}
          assert result.checked_days == 8
          assert result.duration_minutes == 30
          assert result.disagreements == []
        end)

      assert output =~ "Availability audit for @#{username}"
      assert output =~ "no disagreements"
    end

    test "suppresses output when print: false" do
      username = "audit-quiet-#{System.unique_integer([:positive])}"
      setup_bookable_profile(username)

      output =
        capture_io(fn ->
          assert {:ok, _result} =
                   Audit.run(username,
                     start_date: future_monday(),
                     horizon_days: 1,
                     print: false
                   )
        end)

      assert output == ""
    end
  end

  describe "audit/2" do
    test "reports zero disagreements for a profile with empty calendar" do
      # The two availability paths now share the same slot enumeration, so
      # the equivalence holds by construction; this is the sanity test that
      # protects the guarantee against future drift.
      profile = setup_bookable_profile("audit-empty-#{System.unique_integer([:positive])}")

      result = Audit.audit(profile, start_date: future_monday(), horizon_days: 14)

      assert result.disagreements == []
      assert result.checked_days == 15
    end

    test "respects :duration_minutes option" do
      profile = setup_bookable_profile("audit-dur-#{System.unique_integer([:positive])}")

      result =
        Audit.audit(profile, start_date: future_monday(), horizon_days: 1, duration_minutes: 60)

      assert result.duration_minutes == 60
      assert result.disagreements == []
    end

    test "respects :start_date and :horizon_days options" do
      profile = setup_bookable_profile("audit-range-#{System.unique_integer([:positive])}")
      start_date = future_monday()

      result = Audit.audit(profile, start_date: start_date, horizon_days: 5)

      assert result.horizon == {start_date, Date.add(start_date, 5)}
      assert result.checked_days == 6
    end

    test "reaches travel periods for a host who is travelling" do
      # The config `audit/2` builds is compared against itself (month view vs.
      # per-day picker), so a config that ignores trips entirely would still
      # report zero disagreements here — both halves would just be equally
      # wrong about the trip. That is exactly why disagreement counts cannot
      # prove the fix: a trip-blind audit passes this same assertion. What
      # only the fix can do is actually query `travel_periods` for this
      # profile, which is what the telemetry assertion below checks.
      username = "audit-travel-#{System.unique_integer([:positive])}"
      profile = setup_bookable_profile(username)
      monday = future_monday()

      {:ok, trip} =
        Travel.create_period(profile, %{
          label: "Away",
          start_date: monday,
          end_date: Date.add(monday, 2),
          timezone: "Pacific/Auckland"
        })

      {:ok, _day} =
        Travel.set_day(profile, trip, %{
          day_of_week: Date.day_of_week(monday),
          is_available: true,
          start_time: ~T[08:00:00],
          end_time: ~T[10:00:00]
        })

      {result, query_count} =
        count_travel_period_queries(profile.id, fn ->
          Audit.audit(profile, start_date: monday, horizon_days: 3)
        end)

      assert query_count > 0
      assert result.disagreements == []
    end

    test "reports on a profile with no default schedule instead of crashing" do
      # Every profile gains a default schedule on creation and cannot delete it,
      # so this is a database that has lost one. The audit is the tool reached
      # for when availability is behaving oddly, which is exactly the situation
      # such a database produces: it has to survive the state it is diagnosing.
      profile = insert(:profile, username: "audit-nodefault", timezone: "Etc/UTC")

      result = Audit.audit(profile, start_date: future_monday(), horizon_days: 3)

      assert result.schedule_id == nil
      assert result.checked_days == 4
      # The engine's hard-coded fallback hours apply, and both halves of it read
      # the same nil schedule, so they still have to agree with each other.
      assert result.disagreements == []
    end
  end

  # Mirrors `Tymeslot.Availability.TravelQueryBudgetTest`'s own helper: counts
  # queries against `travel_periods` bound to this profile id, so the count is
  # a direct signal that the audited config actually carries `:profile_id`
  # (or a prefetched `:travel_periods` list) rather than a coincidence of
  # `disagreements` staying empty either way.
  defp count_travel_period_queries(profile_id, fun) do
    handler_id = {__MODULE__, make_ref()}
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:tymeslot, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if metadata[:source] == "travel_periods" and
             profile_id in List.wrap(metadata[:params]) do
          send(test_pid, {handler_id, :query})
        end
      end,
      nil
    )

    result =
      try do
        fun.()
      after
        :telemetry.detach(handler_id)
      end

    {result, drain_query_count(handler_id)}
  end

  defp drain_query_count(handler_id, count \\ 0) do
    receive do
      {^handler_id, :query} -> drain_query_count(handler_id, count + 1)
    after
      0 -> count
    end
  end
end
