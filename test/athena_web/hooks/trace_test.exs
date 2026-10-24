defmodule AthenaWeb.Hooks.TraceTest do
  use AthenaWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import ExUnit.CaptureLog

  require Logger

  import Athena.Factory

  setup %{conn: conn} do
    # The test env runs at :warning, which filters the :debug steps out before
    # they reach the capture - hence `async: false` and a real level change.
    previous_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    role = insert(:role, permissions: ["admin", "cohorts.read", "cohorts.create"])
    admin = insert(:account, role: role)
    %{conn: init_test_session(conn, %{"account_id" => admin.id}), admin: admin}
  end

  describe "LiveView tracing" do
    test "logs the mount, the params and every event, with correlating metadata", %{
      conn: conn,
      admin: admin
    } do
      log =
        capture_log([level: :debug], fn ->
          {:ok, lv, _html} = live(conn, ~p"/teaching/cohorts")

          lv
          |> form("form[phx-change='update_filters']", %{"search" => "anything"})
          |> render_change()
        end)

      assert log =~ "[trace] mount"
      assert log =~ "[trace] handle_params"
      assert log =~ "[trace] handle_event"
      assert log =~ ~s(event: "update_filters")

      # The socket id ties the lines together, and is the same value the
      # client puts in its `lv:` topic.
      assert log =~ "trace=phx-"
      assert log =~ "user=#{admin.login}"
      assert log =~ "lv=AthenaWeb.TeachingLive.Cohorts"
    end

    test "redacts sensitive params rather than logging them", %{conn: conn} do
      # Tracing runs at :debug in production too, so anything matching
      # `config :phoenix, :filter_parameters` must never reach the log.
      log =
        capture_log(fn ->
          {:ok, lv, _html} = live(conn, ~p"/teaching/cohorts")

          render_change(lv, "update_filters", %{
            "search" => "visible",
            "token" => "super-secret-value",
            "password" => "hunter2"
          })
        end)

      assert log =~ "[trace] handle_event"
      assert log =~ "visible"
      assert log =~ "[FILTERED]"
      refute log =~ "super-secret-value"
      refute log =~ "hunter2"
    end

    test "steps are silent above debug level", %{conn: conn} do
      Logger.configure(level: :info)

      log =
        capture_log(fn ->
          {:ok, _lv, _html} = live(conn, ~p"/teaching/cohorts")
        end)

      refute log =~ "[trace]"
    end
  end

  describe "HTTP tracing" do
    test "puts the user and route into the request's metadata", %{conn: conn, admin: admin} do
      log =
        capture_log([level: :debug], fn ->
          get(conn, ~p"/dashboard")
        end)

      assert log =~ "[trace] request"
      assert log =~ "user=#{admin.login}"
      assert log =~ "route=GET /dashboard"
    end
  end
end
