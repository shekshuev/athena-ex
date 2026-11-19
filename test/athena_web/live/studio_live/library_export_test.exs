defmodule AthenaWeb.StudioLive.LibraryExportTest do
  use AthenaWeb.ConnCase, async: true
  import Athena.Factory
  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    user =
      insert(:account,
        role:
          insert(:role,
            permissions: ["library.read"],
            policies: %{"library.read" => ["own_only"]}
          )
      )

    question =
      insert(:library_block,
        owner_id: user.id,
        type: :quiz_question,
        title: "A question",
        content: %{"question_type" => "open", "body" => %{"type" => "doc"}}
      )

    text = insert(:library_block, owner_id: user.id, title: "B notes")

    %{
      conn: init_test_session(conn, %{"account_id" => user.id}),
      user: user,
      question: question,
      text: text
    }
  end

  test "mixed selection is counted explicitly and only supported questions are offered", %{
    conn: conn,
    question: question,
    text: text
  } do
    {:ok, view, _} = live(conn, ~p"/studio/library")
    view |> element("#export-select-#{question.id}") |> render_click()
    view |> element("#export-select-#{text.id}") |> render_click()
    assert has_element?(view, "#export-select-#{question.id}[checked]")
    assert has_element?(view, "#export-select-#{text.id}[checked]")
    view |> element("#library-export-open") |> render_click()
    assert has_element?(view, "#library-export-summary", "Questions to export: 1")
    assert has_element?(view, "#library-export-skipped", "1 blocks")
    assert has_element?(view, "#library-export-download:not([disabled])")

    assert has_element?(
             view,
             "#library-export-form[action='/studio/library/export'][method='post']"
           )

    assert has_element?(view, "#library-export-form input[name='ids[]'][value='#{question.id}']")
    assert has_element?(view, "#library-export-help")
    view |> element("#library-export-modal .modal-backdrop") |> render_click()
    assert has_element?(view, "#export-select-#{text.id}[checked]")
  end

  test "non-question selection disables download; filtered scope can still export questions", %{
    conn: conn,
    text: text
  } do
    {:ok, view, _} = live(conn, ~p"/studio/library")
    view |> element("#export-select-#{text.id}") |> render_click()
    view |> element("#library-export-open") |> render_click()
    assert has_element?(view, "#library-export-download[disabled]")

    view
    |> form("#library-export-form", %{"export" => %{"scope" => "filtered", "format" => "gift"}})
    |> render_change()

    assert has_element?(view, "#library-export-summary", "Questions to export: 1")
    assert has_element?(view, "#library-export-download:not([disabled])")
  end

  test "selection survives paging and page selection does not clear other pages", %{
    conn: conn,
    question: question,
    text: text
  } do
    {:ok, view, _} =
      live(conn, ~p"/studio/library?order_by[]=title&order_directions[]=asc&page_size=1")

    view |> element("#library-export-select-page") |> render_click()
    assert has_element?(view, "#export-select-#{question.id}[checked]")

    render_patch(
      view,
      ~p"/studio/library?order_by[]=title&order_directions[]=asc&page_size=1&page=2"
    )

    view |> element("#library-export-select-page") |> render_click()
    assert has_element?(view, "#export-select-#{text.id}[checked]")
    assert has_element?(view, "#library-export-selection-count", "Selected: 2")
    view |> element("#library-export-open") |> render_click()
    assert has_element?(view, "#library-export-summary", "Blocks: 2")
    assert has_element?(view, "#library-export-form input[name='ids[]'][value='#{question.id}']")
  end

  test "empty question filter disables export and counts the full filtered set", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/studio/library?type=text")
    view |> element("#library-export-open") |> render_click()
    assert has_element?(view, "#library-export-summary", "Questions to export: 0")
    assert has_element?(view, "#library-export-download[disabled]")
  end

  test "course export keeps the course-bank scope independently from pin checkboxes", %{
    conn: conn,
    question: question
  } do
    user =
      insert(:account,
        role:
          insert(:role,
            permissions: ["library.read", "courses.read"],
            policies: %{"library.read" => ["own_only"], "courses.read" => ["own_only"]}
          )
      )

    course = insert(:course, owner_id: user.id)
    insert(:course_library_block, course: course, library_block: question)
    conn = init_test_session(conn, %{"account_id" => user.id})
    {:ok, view, _} = live(conn, ~p"/studio/courses/#{course.id}/library")
    view |> element("#export-select-#{question.id}") |> render_click()
    assert has_element?(view, "input[name='pin_#{question.id}'][checked]")
    view |> element("#library-export-open") |> render_click()
    assert has_element?(view, "#library-export-summary", "Questions to export: 1")

    assert has_element?(
             view,
             "#library-export-form input[name='course_id'][value='#{course.id}']"
           )

    assert has_element?(view, "#library-export-form input[name='pinned_only'][value='true']")
  end

  test "Russian locale includes translated export controls and help", %{conn: conn} do
    conn = init_test_session(conn, %{"locale" => "ru"})
    {:ok, view, _} = live(conn, ~p"/studio/library")
    assert has_element?(view, "#library-export-open", "Экспорт вопросов")
    view |> element("#library-export-open") |> render_click()
    assert has_element?(view, "#library-export-summary", "Вопросов к экспорту: 1")
    assert has_element?(view, "#library-export-help", "частичные баллы")
  end
end
