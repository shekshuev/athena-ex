defmodule AthenaWeb.AdminLive.GamificationTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory
  alias Athena.Gamification.Badge

  setup %{conn: conn} do
    role =
      insert(:role,
        permissions: [
          "gamification.read",
          "gamification.create",
          "gamification.update",
          "gamification.delete"
        ]
      )

    admin = insert(:account, role: role)
    conn = init_test_session(conn, %{"account_id" => admin.id})
    %{conn: conn, admin: admin}
  end

  describe "Badges page (Index)" do
    test "renders the badge list", %{conn: conn, admin: admin} do
      {:ok, badge} =
        Athena.Gamification.create_badge(admin, %{
          "key" => "first-hundred",
          "title" => "First Hundred XP",
          "rule" => %{"fact" => "total_xp", "op" => "gte", "value" => 100}
        })

      {:ok, _lv, html} = live(conn, ~p"/admin/gamification")

      assert html =~ badge.title
      assert html =~ "total_xp"
    end

    test "denies access without gamification.read", %{conn: base_conn} do
      account = insert(:account, role: insert(:role, permissions: []))
      conn = init_test_session(base_conn, %{"account_id" => account.id})

      assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/admin/gamification")
    end
  end

  describe "creating a badge" do
    test "creates a badge with a well-formed rule", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/gamification/new")

      html =
        lv
        |> form("#badge-form", %{
          "badge" => %{"key" => "xp-100", "title" => "XP 100", "icon" => "hero-star"}
        })
        |> render_change(%{"rule_text" => ~s({"fact": "total_xp", "op": "gte", "value": 100})})

      assert html =~ "XP 100"

      lv
      |> form("#badge-form", %{"badge" => %{"key" => "xp-100", "title" => "XP 100"}})
      |> render_submit(%{"rule_text" => ~s({"fact": "total_xp", "op": "gte", "value": 100})})

      assert Athena.Repo.get_by(Badge, key: "xp-100")
    end

    test "rejects invalid JSON in the rule field", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/gamification/new")

      html =
        lv
        |> form("#badge-form", %{"badge" => %{"key" => "bad", "title" => "Bad"}})
        |> render_submit(%{"rule_text" => "not json"})

      assert html =~ "not valid JSON"
      refute Athena.Repo.get_by(Badge, key: "bad")
    end

    test "rejects a rule referencing an unknown fact", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/gamification/new")

      html =
        lv
        |> form("#badge-form", %{"badge" => %{"key" => "bad2", "title" => "Bad2"}})
        |> render_submit(%{"rule_text" => ~s({"fact": "nonsense", "op": "gte", "value": 1})})

      assert html =~ "unknown fact"
      refute Athena.Repo.get_by(Badge, key: "bad2")
    end

    test "denies navigating to the new-badge form without gamification.create", %{
      conn: base_conn
    } do
      account =
        insert(:account, role: insert(:role, permissions: ["gamification.read"]))

      conn = init_test_session(base_conn, %{"account_id" => account.id})

      {:ok, _lv, html} =
        live(conn, ~p"/admin/gamification/new") |> follow_redirect(conn, ~p"/admin/gamification")

      assert html =~ "don&#39;t have permission"
    end

    test "denies a raw 'save' event from an account with only gamification.read, even though the form isn't rendered on the index page",
         %{conn: base_conn} do
      account =
        insert(:account, role: insert(:role, permissions: ["gamification.read"]))

      conn = init_test_session(base_conn, %{"account_id" => account.id})

      # Mount the index page (live_action: :index — no form in the DOM at
      # all), then drive the "save" event directly, exactly as a modified
      # client / forged socket frame would, bypassing any UI-level guard.
      {:ok, lv, _html} = live(conn, ~p"/admin/gamification")

      render_submit(lv, "save", %{
        "badge" => %{"key" => "forged", "title" => "Forged"},
        "rule_text" => ~s({"fact": "total_xp", "op": "gte", "value": 1})
      })

      refute Athena.Repo.get_by(Badge, key: "forged")
    end
  end

  describe "toggling and deleting a badge" do
    test "toggles a badge active/inactive", %{conn: conn, admin: admin} do
      {:ok, badge} =
        Athena.Gamification.create_badge(admin, %{
          "key" => "toggle-me",
          "title" => "Toggle Me",
          "rule" => %{"fact" => "total_xp", "op" => "gte", "value" => 1}
        })

      {:ok, lv, _html} = live(conn, ~p"/admin/gamification")

      lv |> element("button[phx-value-id='#{badge.id}']", "Active") |> render_click()

      refute Athena.Repo.get!(Badge, badge.id).is_active
    end

    test "deletes a badge", %{conn: conn, admin: admin} do
      {:ok, badge} =
        Athena.Gamification.create_badge(admin, %{
          "key" => "delete-me",
          "title" => "Delete Me",
          "rule" => %{"fact" => "total_xp", "op" => "gte", "value" => 1}
        })

      {:ok, lv, _html} = live(conn, ~p"/admin/gamification")

      lv |> element("button[phx-value-id='#{badge.id}'][phx-click='delete']") |> render_click()

      refute Athena.Repo.get(Badge, badge.id)
    end

    test "does not delete a badge for an account without gamification.delete", %{
      conn: base_conn,
      admin: admin
    } do
      {:ok, badge} =
        Athena.Gamification.create_badge(admin, %{
          "key" => "keep-me",
          "title" => "Keep Me",
          "rule" => %{"fact" => "total_xp", "op" => "gte", "value" => 1}
        })

      account =
        insert(:account,
          role: insert(:role, permissions: ["gamification.read", "gamification.update"])
        )

      conn = init_test_session(base_conn, %{"account_id" => account.id})
      {:ok, lv, _html} = live(conn, ~p"/admin/gamification")

      lv |> element("button[phx-value-id='#{badge.id}'][phx-click='delete']") |> render_click()

      assert Athena.Repo.get(Badge, badge.id)
    end
  end

  describe "testing a rule against a student" do
    test "shows that a qualifying account would earn the badge", %{conn: conn} do
      student = insert(:account)
      insert(:account_stats, account_id: student.id, total_xp: 500)

      {:ok, lv, _html} = live(conn, ~p"/admin/gamification/new")

      lv
      |> form("#badge-form", %{"badge" => %{"key" => "k", "title" => "T"}})
      |> render_change(%{"rule_text" => ~s({"fact": "total_xp", "op": "gte", "value": 100})})

      html =
        lv
        |> form("form[phx-submit='test_rule']", %{"login" => student.login})
        |> render_submit()

      assert html =~ "would earn this badge"
    end

    test "shows an error for an unknown login", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/gamification/new")

      html =
        lv
        |> form("form[phx-submit='test_rule']", %{"login" => "ghost_user"})
        |> render_submit()

      assert html =~ "No account with login"
    end
  end
end
