defmodule AthenaWeb.StudioLive.CompetitionsTest do
  use AthenaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Athena.Factory
  use Oban.Testing, repo: Athena.Repo

  alias Athena.Content.{Course, Workers.CourseDeepCopy}
  alias Athena.Repo

  setup %{conn: conn} do
    role = insert(:role, permissions: ["competitions.read", "competitions.update"])
    author = insert(:account, role: role)

    source =
      insert(:course,
        type: :competition,
        owner_id: author.id,
        scoring: %Athena.Content.ScoringRules{mode: :dynamic, initial: 700}
      )

    conn = init_test_session(conn, %{"account_id" => author.id})
    %{conn: conn, author: author, source: source}
  end

  defp open_duplicate(view, source) do
    view |> element("#duplicate-competition-#{source.id}") |> render_click()
  end

  test "creates a competition draft and enqueues the shared deep copy worker", %{
    conn: conn,
    source: source,
    author: author
  } do
    {:ok, view, _} = live(conn, ~p"/studio/competitions")
    open_duplicate(view, source)
    assert has_element?(view, "#duplicate-competition-form input[name=title]")

    view
    |> form("#duplicate-competition-form", %{"title" => "Competition Copy"})
    |> render_submit()

    copy = Repo.get_by!(Course, title: "Competition Copy")
    assert copy.type == :competition
    assert copy.scoring == source.scoring
    assert copy.owner_id == author.id
    assert copy.status == :draft
    assert copy.copy_status == :copying
    assert copy.source_course_id == source.id

    assert_enqueued(
      worker: CourseDeepCopy,
      args: %{new_course_id: copy.id, source_course_id: source.id}
    )

    assert has_element?(view, "#competitions tr#courses-#{copy.id}")
    refute has_element?(view, "a[href='/studio/competitions/#{copy.id}/builder']")
    refute has_element?(view, "#duplicate-competition-#{copy.id}")

    assert :ok =
             CourseDeepCopy.perform(%Oban.Job{
               args: %{"new_course_id" => copy.id, "source_course_id" => source.id}
             })

    assert has_element?(view, "a[href='/studio/competitions/#{copy.id}/builder']")
    assert has_element?(view, "#duplicate-competition-#{copy.id}")
  end

  test "shows validation errors and retains the entered title", %{conn: conn, source: source} do
    {:ok, view, _} = live(conn, ~p"/studio/competitions")
    open_duplicate(view, source)
    view |> form("#duplicate-competition-form", %{"title" => "ab"}) |> render_submit()
    assert has_element?(view, "#duplicate-competition-error")
    assert has_element?(view, "#duplicate-competition-form input[value=ab]")
    refute Repo.get_by(Course, title: "ab")
  end

  test "can cancel without creating a copy", %{conn: conn, source: source} do
    {:ok, view, _} = live(conn, ~p"/studio/competitions")
    open_duplicate(view, source)

    view
    |> element("#duplicate-competition-form button[phx-click=cancel_duplicate]")
    |> render_click()

    assert Repo.aggregate(Course, :count) == 1
  end

  test "retries a failed copy", %{conn: conn, source: source, author: author} do
    copy =
      insert(:course,
        type: :competition,
        owner_id: author.id,
        source_course_id: source.id,
        copy_status: :failed
      )

    {:ok, view, _} = live(conn, ~p"/studio/competitions")
    view |> element("#retry-competition-#{copy.id}") |> render_click()
    assert Repo.get!(Course, copy.id).copy_status == :copying

    assert_enqueued(
      worker: CourseDeepCopy,
      args: %{new_course_id: copy.id, source_course_id: source.id}
    )

    refute has_element?(view, "#retry-competition-#{copy.id}")
  end

  test "read access cannot duplicate or retry even through forged events", %{
    conn: conn,
    source: source
  } do
    reader = insert(:account, role: insert(:role, permissions: ["competitions.read"]))

    copy =
      insert(:course,
        type: :competition,
        owner_id: source.owner_id,
        source_course_id: source.id,
        copy_status: :failed
      )

    conn = init_test_session(conn, %{"account_id" => reader.id})
    {:ok, view, _} = live(conn, ~p"/studio/competitions")
    refute has_element?(view, "#duplicate-competition-#{source.id}")
    refute has_element?(view, "#retry-competition-#{copy.id}")
    render_click(view, "duplicate_click", %{"id" => source.id})
    assert has_element?(view, "#duplicate-competition-form input[value='']")
    assert has_element?(view, "#flash-error")
    render_click(view, "retry_duplicate_click", %{"id" => copy.id})
    assert Repo.get!(Course, copy.id).copy_status == :failed
    assert Repo.aggregate(Course, :count) == 2
  end
end
