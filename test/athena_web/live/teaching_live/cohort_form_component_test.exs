defmodule AthenaWeb.TeachingLive.CohortFormComponentTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory
  alias Athena.Learning

  setup %{conn: conn} do
    role =
      insert(:role,
        permissions: ["cohorts.read", "cohorts.create", "cohorts.update", "instructors.read"]
      )

    account = insert(:account, role: role)

    conn = init_test_session(conn, %{"account_id" => account.id})
    %{conn: conn, current_user: account}
  end

  describe "Cohort Form Component" do
    test "validates required fields on change", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/teaching/cohorts/new")

      html =
        lv
        |> form("#cohort-form", %{
          "cohort" => %{"name" => ""}
        })
        |> render_change()

      assert html =~ "can&#39;t be blank"
    end

    test "creates a new cohort and assigns instructors via autocomplete", %{
      conn: conn,
      current_user: current_user
    } do
      account = insert(:account, login: "john_doe")
      instructor = insert(:instructor, owner_id: account.id, title: "Elixir Master")

      {:ok, lv, _html} = live(conn, ~p"/teaching/cohorts/new")

      lv
      |> element("input[phx-keyup='search_instructors']")
      |> render_keyup(%{"value" => "john_doe"})

      lv
      |> element("li", "john_doe")
      |> render_click()

      lv
      |> form("#cohort-form", %{
        "cohort" => %{
          "name" => "Backend Dev Bootcamp",
          "description" => "Intensive Elixir course",
          "type" => "team"
        }
      })
      |> render_submit()

      assert_patch(lv, ~p"/teaching/cohorts")

      {:ok, {cohorts, _meta}} = Learning.list_cohorts(current_user, %{})
      assert length(cohorts) == 1
      cohort = hd(cohorts)

      assert cohort.name == "Backend Dev Bootcamp"
      assert cohort.description == "Intensive Elixir course"
      assert cohort.type == :team

      assert length(cohort.instructors) == 1
      assert hd(cohort.instructors).id == instructor.id

      assert render(lv) =~ "Cohort created successfully"
    end

    test "updates an existing cohort and adds a new instructor", %{
      conn: conn,
      current_user: current_user
    } do
      cohort = insert(:cohort, name: "Old Cohort Name", type: :academic)

      account = insert(:account, login: "jane_smith")
      new_instructor = insert(:instructor, owner_id: account.id, title: "Ruby Guru")

      {:ok, lv, _html} = live(conn, ~p"/teaching/cohorts/#{cohort.id}/edit")

      lv
      |> element("input[phx-keyup='search_instructors']")
      |> render_keyup(%{"value" => "jane_smith"})

      lv
      |> element("li", "jane_smith")
      |> render_click()

      lv
      |> form("#cohort-form", %{
        "cohort" => %{
          "name" => "Updated Cohort Name",
          "type" => "academic"
        }
      })
      |> render_submit()

      assert_patch(lv, ~p"/teaching/cohorts")

      {:ok, updated_cohort} = Learning.get_cohort(current_user, cohort.id)

      assert updated_cohort.name == "Updated Cohort Name"
      assert updated_cohort.type == :academic
      assert length(updated_cohort.instructors) == 1
      assert hd(updated_cohort.instructors).id == new_instructor.id

      assert render(lv) =~ "Cohort updated successfully"
    end
  end
end
