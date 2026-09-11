defmodule AthenaWeb.TeachingLive.SprintsTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory
  alias Athena.Gamification.Sprint

  setup %{conn: conn} do
    role = insert(:role, permissions: ["cohorts.read", "cohorts.update"])
    instructor = insert(:account, role: role)
    cohort = insert(:cohort, name: "Group A")
    conn = init_test_session(conn, %{"account_id" => instructor.id})
    %{conn: conn, instructor: instructor, cohort: cohort}
  end

  test "renders the cohort picker", %{conn: conn, cohort: cohort} do
    {:ok, _lv, html} = live(conn, ~p"/teaching/sprints")
    assert html =~ "Sprints"
    assert html =~ cohort.name
  end

  test "creates a sprint via the form using a datetime-local style value", %{
    conn: conn,
    cohort: cohort
  } do
    {:ok, lv, _html} = live(conn, ~p"/teaching/sprints")

    lv
    |> element("form[phx-change='select_cohort']")
    |> render_change(%{"cohort_id" => cohort.id})

    now = DateTime.utc_now()
    starts_at = Calendar.strftime(now, "%Y-%m-%dT%H:%M")
    ends_at = Calendar.strftime(DateTime.add(now, 3600, :second), "%Y-%m-%dT%H:%M")

    html =
      lv
      |> form("#sprint-form", %{
        "sprint" => %{
          "title" => "Exam push",
          "starts_at" => starts_at,
          "ends_at" => ends_at,
          "xp_multiplier" => "2"
        }
      })
      |> render_submit()

    assert html =~ "Exam push"
    assert Athena.Repo.get_by(Sprint, cohort_id: cohort.id, title: "Exam push")
  end

  test "shows a permission error when the instructor doesn't manage the cohort", %{
    conn: conn,
    cohort: cohort
  } do
    outsider_role = insert(:role, permissions: ["cohorts.read"])
    outsider = insert(:account, role: outsider_role)
    conn = init_test_session(conn, %{"account_id" => outsider.id})

    {:ok, lv, _html} = live(conn, ~p"/teaching/sprints")

    lv
    |> element("form[phx-change='select_cohort']")
    |> render_change(%{"cohort_id" => cohort.id})

    now = DateTime.utc_now()
    starts_at = Calendar.strftime(now, "%Y-%m-%dT%H:%M")
    ends_at = Calendar.strftime(DateTime.add(now, 3600, :second), "%Y-%m-%dT%H:%M")

    html =
      lv
      |> form("#sprint-form", %{
        "sprint" => %{
          "title" => "Nope",
          "starts_at" => starts_at,
          "ends_at" => ends_at,
          "xp_multiplier" => "2"
        }
      })
      |> render_submit()

    assert html =~ "don&#39;t manage this cohort"
    refute Athena.Repo.get_by(Sprint, cohort_id: cohort.id, title: "Nope")
  end

  test "deletes a sprint", %{conn: conn, cohort: cohort, instructor: instructor} do
    {:ok, sprint} =
      Athena.Gamification.create_sprint(instructor, %{
        "cohort_id" => cohort.id,
        "title" => "Delete me",
        "starts_at" => DateTime.utc_now() |> DateTime.truncate(:second),
        "ends_at" =>
          DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second),
        "xp_multiplier" => "1.5"
      })

    {:ok, lv, _html} = live(conn, ~p"/teaching/sprints")

    lv
    |> element("form[phx-change='select_cohort']")
    |> render_change(%{"cohort_id" => cohort.id})

    lv |> element("button[phx-value-id='#{sprint.id}']") |> render_click()

    refute Athena.Repo.get(Sprint, sprint.id)
  end
end
