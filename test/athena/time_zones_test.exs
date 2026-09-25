defmodule Athena.TimeZonesTest do
  # Touches the app timezone (global application env).
  use ExUnit.Case, async: false

  alias Athena.TimeZones

  setup do
    previous = Application.get_env(:athena, :app_timezone)
    Application.put_env(:athena, :app_timezone, "Europe/Moscow")
    Process.delete(:athena_user_timezone)

    on_exit(fn -> Application.put_env(:athena, :app_timezone, previous) end)
  end

  describe "user timezone" do
    test "falls back to the app timezone when unset or invalid" do
      assert TimeZones.user_timezone() == "Europe/Moscow"
      assert TimeZones.put_user_timezone("Not/AZone") == "Europe/Moscow"
      assert TimeZones.put_user_timezone(nil) == "Europe/Moscow"
    end

    test "uses a valid browser timezone" do
      assert TimeZones.put_user_timezone("Asia/Tokyo") == "Asia/Tokyo"
      assert TimeZones.user_timezone() == "Asia/Tokyo"
    end
  end

  describe "display" do
    test "format/2 renders UTC values in the user timezone" do
      TimeZones.put_user_timezone("Asia/Tokyo")
      assert TimeZones.format(~U[2026-09-25 20:30:00Z], "%d.%m.%Y %H:%M") == "26.09.2026 05:30"
      assert TimeZones.format(nil, "%d.%m.%Y") == ""
    end

    test "input_value/1 gives the local wall-clock for datetime-local inputs" do
      TimeZones.put_user_timezone("Europe/Moscow")
      assert TimeZones.input_value(~U[2026-09-25 11:00:00Z]) == "2026-09-25T14:00"
      assert TimeZones.input_value("2026-09-25T11:00:00Z") == "2026-09-25T14:00"
      assert TimeZones.input_value("2026-09-25T14:00") == "2026-09-25T14:00"
      assert TimeZones.input_value(nil) == ""
    end
  end

  describe "input" do
    test "local_to_utc/2 reads wall-clock values in the user timezone" do
      TimeZones.put_user_timezone("Europe/Moscow")
      assert TimeZones.local_to_utc("2026-09-25T14:00") == {:ok, ~U[2026-09-25 11:00:00Z]}
      assert TimeZones.local_to_utc("2026-09-25T14:00:30") == {:ok, ~U[2026-09-25 11:00:30Z]}
    end

    test "local_to_utc/2 keeps absolute values absolute" do
      assert TimeZones.local_to_utc("2026-09-25T14:00:00+05:00", "Europe/Moscow") ==
               {:ok, ~U[2026-09-25 09:00:00Z]}
    end

    test "local_to_utc/2 resolves DST gaps and overlaps" do
      # 02:30 doesn't exist on the spring-forward night in Berlin.
      assert TimeZones.local_to_utc("2026-03-29T02:30", "Europe/Berlin") ==
               {:ok, ~U[2026-03-29 01:00:00Z]}

      # 02:30 happens twice on the fall-back night; the earlier one wins.
      assert TimeZones.local_to_utc("2026-10-25T02:30", "Europe/Berlin") ==
               {:ok, ~U[2026-10-25 00:30:00Z]}
    end

    test "local_to_utc/2 rejects garbage" do
      assert TimeZones.local_to_utc("tomorrow", "Europe/Moscow") == :error
    end

    test "localize_params/2 only rewrites the given, parsable keys" do
      TimeZones.put_user_timezone("Europe/Moscow")

      params = %{
        "starts_at" => "2026-09-25T14:00",
        "ends_at" => "",
        "title" => "2026-09-25T14:00"
      }

      assert TimeZones.localize_params(params, ~w(starts_at ends_at)) == %{
               "starts_at" => "2026-09-25T11:00:00Z",
               "ends_at" => "",
               "title" => "2026-09-25T14:00"
             }
    end

    test "local_day_start/2 gives UTC bounds of a local calendar day" do
      TimeZones.put_user_timezone("Europe/Moscow")
      assert TimeZones.local_day_start("2026-05-01") == {:ok, ~U[2026-04-30 21:00:00Z]}
      assert TimeZones.local_day_start("2026-05-10", 1) == {:ok, ~U[2026-05-10 21:00:00Z]}
      assert TimeZones.local_day_start("") == :error
    end
  end

  describe "app day boundaries" do
    test "start_of_day/1 is app-timezone midnight expressed in UTC" do
      assert TimeZones.start_of_day(~D[2026-09-28]) == ~U[2026-09-27 21:00:00Z]
    end

    test "today/0 and this_week_start/0 follow the app timezone" do
      today = TimeZones.today()

      assert today ==
               DateTime.utc_now() |> DateTime.shift_zone!("Europe/Moscow") |> DateTime.to_date()

      assert TimeZones.this_week_start() == Date.beginning_of_week(today)
    end
  end
end
