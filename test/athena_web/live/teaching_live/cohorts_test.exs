defmodule AthenaWeb.TeachingLive.CohortsTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory

  setup %{conn: conn} do
    role =
      insert(:role,
        permissions: ["cohorts.read", "cohorts.create", "cohorts.update", "cohorts.delete"]
      )

    admin = insert(:account, role: role)
    conn = init_test_session(conn, %{"account_id" => admin.id})
    %{conn: conn, admin: admin}
  end

  describe "Cohorts page (Index)" do
    test "should render the cohorts list", %{conn: conn} do
      cohort = insert(:cohort, name: "Autumn Cohort 2026")

      {:ok, _lv, html} = live(conn, ~p"/teaching/cohorts")

      assert html =~ "Cohorts"
      assert html =~ "Add Cohort"
      assert html =~ cohort.name
    end

    test "should handle search functionality", %{conn: conn} do
      insert(:cohort, name: "Frontend Developers")
      insert(:cohort, name: "Backend Masters")

      {:ok, lv, _html} = live(conn, ~p"/teaching/cohorts")

      html =
        lv
        |> form("form[phx-change='search']", %{"search" => "Frontend"})
        |> render_change()

      assert html =~ "Frontend Developers"
      refute html =~ "Backend Masters"
    end
  end

  describe "Cohorts page (Create/Edit actions)" do
    test "should open the create cohort slide-over via URL", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/teaching/cohorts/new")

      assert html =~ "Create Cohort"
      assert html =~ "Cohort Name"
    end

    test "should open the edit cohort slide-over via URL", %{conn: conn} do
      cohort = insert(:cohort, name: "Target Cohort")

      {:ok, _lv, html} = live(conn, ~p"/teaching/cohorts/#{cohort.id}/edit")

      assert html =~ "Edit Cohort"
      assert html =~ "Target Cohort"
    end
  end

  describe "Cohorts page (Delete action)" do
    test "should show confirmation modal on delete click", %{conn: conn} do
      cohort = insert(:cohort, name: "Doomed Cohort")

      {:ok, lv, _html} = live(conn, ~p"/teaching/cohorts")

      html =
        lv
        |> element("button[phx-click='delete_click'][phx-value-id='#{cohort.id}']")
        |> render_click()

      assert html =~ "Are you sure you want to delete this cohort?"
    end

    test "should delete the cohort when confirmed", %{conn: conn} do
      cohort = insert(:cohort, name: "Doomed Cohort")

      {:ok, lv, _html} = live(conn, ~p"/teaching/cohorts")

      lv
      |> element("button[phx-click='delete_click'][phx-value-id='#{cohort.id}']")
      |> render_click()

      html = render_click(lv, "confirm_delete")

      assert html =~ "Cohort deleted successfully"
      refute html =~ "Doomed Cohort"
    end
  end

  describe "Permissions & ACL" do
    setup %{conn: conn} do
      role = insert(:role, permissions: ["cohorts.read"])
      limited_user = insert(:account, role: role)
      conn = init_test_session(conn, %{"account_id" => limited_user.id})

      %{conn: conn, limited_user: limited_user}
    end

    test "should not see action buttons if user only has read permission", %{conn: conn} do
      insert(:cohort)
      {:ok, _lv, html} = live(conn, ~p"/teaching/cohorts")

      assert html =~ "Cohorts"

      refute html =~ "Add Cohort"
      refute html =~ "hero-pencil-square"
      refute html =~ "hero-trash"

      assert html =~ "hero-eye"
    end

    test "should redirect from /new if user lacks create permission", %{conn: conn} do
      {:error, {:live_redirect, %{to: "/teaching/cohorts"}}} =
        live(conn, ~p"/teaching/cohorts/new")
    end

    test "should redirect from /edit if user lacks update permission", %{conn: conn} do
      target = insert(:cohort)

      {:error, {:live_redirect, %{to: "/teaching/cohorts"}}} =
        live(conn, ~p"/teaching/cohorts/#{target.id}/edit")
    end

    test "should show error flash on delete_click if user lacks delete permission", %{conn: conn} do
      target = insert(:cohort)
      {:ok, lv, _html} = live(conn, ~p"/teaching/cohorts")

      html = render_click(lv, "delete_click", %{"id" => target.id})

      assert html =~ "Permission denied."
    end
  end

  describe "Permissions & ACL (Policies: own_only)" do
    setup %{conn: conn} do
      role =
        insert(:role,
          permissions: ["cohorts.read", "cohorts.update", "cohorts.delete"],
          policies: %{
            "cohorts.update" => ["own_only"],
            "cohorts.delete" => ["own_only"]
          }
        )

      instructor = insert(:account, role: role)
      conn = init_test_session(conn, %{"account_id" => instructor.id})

      %{conn: conn, instructor: instructor}
    end

    test "shows action buttons ONLY for owned cohorts", %{conn: conn, instructor: instructor} do
      my_cohort = insert(:cohort, name: "My Precious", owner_id: instructor.id)
      other_cohort = insert(:cohort, name: "Not Mine", owner_id: Ecto.UUID.generate())

      {:ok, _lv, html} = live(conn, ~p"/teaching/cohorts")

      assert html =~ "My Precious"
      assert html =~ "Not Mine"

      assert html =~ ~p"/teaching/cohorts/#{my_cohort.id}/edit"
      refute html =~ ~p"/teaching/cohorts/#{other_cohort.id}/edit"

      assert html =~ ~s(phx-value-id="#{my_cohort.id}")
      refute html =~ ~s(phx-value-id="#{other_cohort.id}")
    end

    test "shows permission denied flash if forcing delete on someone else's cohort", %{conn: conn} do
      other_cohort = insert(:cohort, owner_id: Ecto.UUID.generate())

      {:ok, lv, _html} = live(conn, ~p"/teaching/cohorts")

      html = render_click(lv, "delete_click", %{"id" => other_cohort.id})

      assert html =~ "Permission denied."
    end

    test "redirects with permission denied flash if forcing edit on someone else's cohort", %{
      conn: conn
    } do
      other_cohort = insert(:cohort, owner_id: Ecto.UUID.generate())

      assert {:error, {:live_redirect, %{to: "/teaching/cohorts", flash: flash}}} =
               live(conn, ~p"/teaching/cohorts/#{other_cohort.id}/edit")

      assert flash["error"] == "Permission denied."
    end
  end
end
