defmodule AthenaWeb.TeachingLive.MembershipFormComponentTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory
  alias Athena.Learning

  setup %{conn: conn} do
    role = insert(:role, permissions: ["cohorts.read", "cohorts.update"])
    account = insert(:account, role: role)

    conn = init_test_session(conn, %{"account_id" => account.id})
    %{conn: conn, current_user: account}
  end

  describe "Membership Form Component" do
    test "shows error when saving without selecting a student", %{conn: conn} do
      cohort = insert(:cohort)

      {:ok, lv, _html} = live(conn, ~p"/teaching/cohorts/#{cohort.id}/add_student")

      html =
        lv
        |> form("#membership-form")
        |> render_submit()

      assert html =~ "Please select a student."
    end

    test "searches and adds a student to the cohort via autocomplete", %{conn: conn} do
      cohort = insert(:cohort)
      student_account = insert(:account, login: "super_student")

      {:ok, lv, _html} = live(conn, ~p"/teaching/cohorts/#{cohort.id}/add_student")

      lv
      |> element("input[phx-keyup='search_accounts']")
      |> render_keyup(%{"value" => "super_student"})

      lv
      |> element("li", "super_student")
      |> render_click()

      lv
      |> form("#membership-form")
      |> render_submit()

      assert_patch(lv, ~p"/teaching/cohorts/#{cohort.id}")

      {:ok, {memberships, _meta}} = Learning.list_cohort_memberships(cohort.id)
      assert length(memberships) == 1
      assert hd(memberships).account_id == student_account.id

      assert render(lv) =~ "Student successfully added"
    end

    test "shows error if the student is already in the cohort", %{conn: conn} do
      cohort = insert(:cohort)
      student_account = insert(:account, login: "existing_student")

      {:ok, _membership} = Learning.add_student_to_cohort(cohort.id, student_account.id)

      {:ok, lv, _html} = live(conn, ~p"/teaching/cohorts/#{cohort.id}/add_student")

      lv
      |> element("input[phx-keyup='search_accounts']")
      |> render_keyup(%{"value" => "existing_student"})

      lv
      |> element("li", "existing_student")
      |> render_click()

      html =
        lv
        |> form("#membership-form")
        |> render_submit()

      assert html =~ "This student is already in the cohort."
    end
  end
end
