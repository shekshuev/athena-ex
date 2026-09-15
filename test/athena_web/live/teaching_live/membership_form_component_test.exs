defmodule AthenaWeb.TeachingLive.MembershipFormComponentTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory
  alias Athena.Learning

  setup %{conn: conn} do
    # Deliberately no "users.read" permission: the cohort search must work
    # for any instructor who can manage cohorts, without the unrelated
    # user-management ACL permission.
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

      html = render(lv)
      assert html =~ "Student successfully added"

      assert_patch(
        lv,
        ~p"/teaching/cohorts/#{cohort.id}?order_by[]=inserted_at&order_directions[]=desc&page=1&page_size=20"
      )

      {:ok, {memberships, _meta}} = Learning.list_cohort_memberships(cohort.id)
      assert length(memberships) == 1
      assert hd(memberships).account_id == student_account.id
    end

    test "shows error if the student is already in the cohort", %{
      conn: conn,
      current_user: current_user
    } do
      cohort = insert(:cohort)
      student_account = insert(:account, login: "existing_student")

      {:ok, lv, _html} = live(conn, ~p"/teaching/cohorts/#{cohort.id}/add_student")

      lv
      |> element("input[phx-keyup='search_accounts']")
      |> render_keyup(%{"value" => "existing_student"})

      lv
      |> element("li", "existing_student")
      |> render_click()

      # Simulate a race: the student gets added to the cohort (by this or
      # another instructor) between the search/select and this submit.
      {:ok, _membership} =
        Learning.add_student_to_cohort(current_user, cohort.id, student_account.id)

      html =
        lv
        |> form("#membership-form")
        |> render_submit()

      assert html =~ "This student is already in the cohort."
    end

    test "finds a student by profile name (ФИО) rather than login", %{conn: conn} do
      cohort = insert(:cohort)
      student_account = insert(:account, login: "unrelated_login_123")
      insert(:profile, owner: student_account, first_name: "Иван", last_name: "Петров")

      {:ok, lv, _html} = live(conn, ~p"/teaching/cohorts/#{cohort.id}/add_student")

      html =
        lv
        |> element("input[phx-keyup='search_accounts']")
        |> render_keyup(%{"value" => "Петров"})

      assert html =~ "Петров Иван"
      assert html =~ "unrelated_login_123"
    end

    test "does not offer a student who is already a member of the cohort", %{
      conn: conn,
      current_user: current_user
    } do
      cohort = insert(:cohort)
      student_account = insert(:account, login: "already_in_cohort")

      {:ok, _membership} =
        Learning.add_student_to_cohort(current_user, cohort.id, student_account.id)

      {:ok, lv, _html} = live(conn, ~p"/teaching/cohorts/#{cohort.id}/add_student")

      html =
        lv
        |> element("input[phx-keyup='search_accounts']")
        |> render_keyup(%{"value" => "already_in_cohort"})

      # The roster below the search form may legitimately show this login
      # elsewhere on the page, so assert specifically against the search
      # result option, not the raw substring.
      refute html =~ ~s(phx-value-login="already_in_cohort")
    end
  end
end
