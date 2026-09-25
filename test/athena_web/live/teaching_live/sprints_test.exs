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
      |> form("#sprint-form", %{"sprint" => %{"title" => "Exam push", "xp_multiplier" => "2"}})
      # Dates live in the picker's hidden inputs, which the JS hook fills in.
      |> render_submit(%{"sprint" => %{"starts_at" => starts_at, "ends_at" => ends_at}})

    assert html =~ "Exam push"
    assert Athena.Repo.get_by(Sprint, cohort_id: cohort.id, title: "Exam push")
  end

  test "reads and shows sprint times in the browser's timezone, stores UTC", %{
    conn: conn,
    cohort: cohort
  } do
    conn = put_connect_params(conn, %{"timezone" => "Europe/Moscow"})
    {:ok, lv, _html} = live(conn, ~p"/teaching/sprints")

    lv
    |> element("form[phx-change='select_cohort']")
    |> render_change(%{"cohort_id" => cohort.id})

    lv
    |> form("#sprint-form", %{"sprint" => %{"title" => "Moscow sprint", "xp_multiplier" => "2"}})
    |> render_submit(%{
      "sprint" => %{"starts_at" => "2030-10-01T14:00", "ends_at" => "2030-10-01T18:30"}
    })

    sprint = Athena.Repo.get_by!(Sprint, cohort_id: cohort.id, title: "Moscow sprint")
    assert sprint.starts_at == ~U[2030-10-01 11:00:00Z]
    assert sprint.ends_at == ~U[2030-10-01 15:30:00Z]

    assert has_element?(lv, "#sprint-#{sprint.id}", "01.10 14:00 — 01.10 18:30")
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
      |> form("#sprint-form", %{"sprint" => %{"title" => "Nope", "xp_multiplier" => "2"}})
      # Dates live in the picker's hidden inputs, which the JS hook fills in.
      |> render_submit(%{"sprint" => %{"starts_at" => starts_at, "ends_at" => ends_at}})

    assert html =~ "don&#39;t manage this cohort"
    refute Athena.Repo.get_by(Sprint, cohort_id: cohort.id, title: "Nope")
  end

  test "deletes a sprint after confirming in the modal", %{
    conn: conn,
    cohort: cohort,
    instructor: instructor
  } do
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

    html = lv |> element("button[phx-value-id='#{sprint.id}']") |> render_click()

    assert html =~ "Delete this sprint?"
    assert Athena.Repo.get(Sprint, sprint.id)

    lv |> element("#delete-sprint-modal button", "Delete") |> render_click()

    refute Athena.Repo.get(Sprint, sprint.id)
  end
end
