defmodule AthenaWeb.AuditTrailTest do
  @moduledoc """
  The audit trail end to end: a real action through a LiveView must leave an
  `:info` event correlated to the session that caused it, with the debug
  tracing off - which is how production runs.
  """
  use AthenaWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import ExUnit.CaptureLog
  import Athena.Factory

  require Logger

  setup %{conn: conn} do
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)

    role = insert(:role, permissions: ["admin", "cohorts.read", "cohorts.create"])
    admin = insert(:account, role: role)
    %{conn: init_test_session(conn, %{"account_id" => admin.id}), admin: admin}
  end

  test "creating a cohort records the event, correlated, without debug noise", %{
    conn: conn,
    admin: admin
  } do
    log =
      capture_log(fn ->
        {:ok, lv, _html} = live(conn, ~p"/teaching/cohorts/new")

        lv
        |> form("#cohort-form", %{"cohort" => %{"name" => "ИВТ-21"}})
        |> render_submit()
      end)

    assert log =~ "[event] cohort.created"
    assert log =~ "name=ИВТ-21"
    assert log =~ "by=#{admin.id}"

    # The correlation id is on the event even though the step tracing is off.
    assert log =~ "trace=phx-"
    assert log =~ "user=#{admin.login}"

    refute log =~ "[trace]"
    refute log =~ "QUERY OK"
  end

  test "a refused action is recorded at warning", %{conn: _conn} do
    # A role that may read cohorts but not create them.
    user = insert(:account, role: insert(:role, permissions: ["cohorts.read"]))

    log =
      capture_log(fn ->
        Athena.Learning.create_cohort(user, %{"name" => "Nope"})
      end)

    assert log =~ "[warning]"
    assert log =~ "[event] cohort.create_refused"
    assert log =~ "by=#{user.id}"
  end
end
