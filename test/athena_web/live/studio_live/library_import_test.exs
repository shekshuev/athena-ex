defmodule AthenaWeb.StudioLive.LibraryImportTest do
  use AthenaWeb.ConnCase, async: true
  import Athena.Factory
  import Phoenix.LiveViewTest
  import Ecto.Query

  alias Athena.Content.LibraryBlock
  alias Athena.Repo

  setup %{conn: conn} do
    user =
      insert(:account,
        role:
          insert(:role,
            permissions: ["library.read", "library.create"],
            policies: %{"library.read" => ["own_only"]}
          )
      )

    %{conn: init_test_session(conn, %{"account_id" => user.id}), user: user}
  end

  defp upload(view, filename, data, format) do
    view |> form("#library-import-form", %{"import" => %{"format" => format}}) |> render_change()

    upload =
      file_input(view, "#library-import-form", :questions, [
        %{name: filename, content: data, type: "text/plain"}
      ])

    render_upload(upload, filename)
    view |> form("#library-import-form", %{"import" => %{"format" => format}}) |> render_submit()
  end

  test "uploads GIFT and reports imported and skipped questions with reasons", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _} = live(conn, ~p"/studio/library")
    view |> element("#library-import-open") |> render_click()
    assert has_element?(view, "#library-import-help")
    assert has_element?(view, "#library-import-submit[disabled]")

    upload(
      view,
      "questions.gift",
      "::Imported question::Choose one. {=yes ~no}\n\n::Numerical::Value? {#2}",
      "gift"
    )

    assert has_element?(view, "#library-import-result", "Imported: 1. Skipped: 1.")
    refute has_element?(view, "#library-import-modal.modal-open")
    assert has_element?(view, "#library-import-report:not(.hidden) #library-import-result")
    refute has_element?(view, "#library-import-modal #library-import-result")
    assert has_element?(view, "#library-import-skipped", "Numerical")
    assert has_element?(view, "#library-import-skipped", "Unsupported question type")
    [question] = Repo.all(from b in LibraryBlock, where: b.owner_id == ^user.id)
    assert has_element?(view, "#library_blocks-#{question.id}")
    refute question.is_public
  end

  test "XML upload uses the selected format and creates editable question content", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _} = live(conn, ~p"/studio/library")
    view |> element("#library-import-open") |> render_click()

    upload(
      view,
      "questions.xml",
      "<quiz><question type='essay'><name><text>Imported XML</text></name><questiontext><text>Write something</text></questiontext><responseformat>plain</responseformat></question></quiz>",
      "moodle_xml"
    )

    assert has_element?(view, "#library-import-result", "Imported: 1. Skipped: 0.")
    refute has_element?(view, "#library-import-modal.modal-open")
    assert has_element?(view, "#flash-info", "Imported: 1. Skipped: 0.")
    question = Repo.one!(from b in LibraryBlock, where: b.owner_id == ^user.id)
    assert question.content["question_type"] == "open"
    assert question.content["answer_type"] == "plain_text"
  end

  test "unsupported-only file succeeds with a report; malformed XML shows a file error", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _} = live(conn, ~p"/studio/library")
    view |> element("#library-import-open") |> render_click()
    upload(view, "unsupported.gift", "::Numerical::Value? {#2}", "gift")
    assert has_element?(view, "#library-import-result", "Imported: 0. Skipped: 1.")
    refute has_element?(view, "#library-import-modal.modal-open")

    assert has_element?(
             view,
             "#library-import-report:not(.hidden) #library-import-skipped",
             "Numerical"
           )

    assert has_element?(view, "#flash-error", "Imported: 0. Skipped: 1.")
    view |> element("#library-import-open") |> render_click()
    upload(view, "broken.xml", "<quiz><question>", "moodle_xml")
    assert has_element?(view, "#library-import-error")

    assert has_element?(
             view,
             "#library-import-modal.modal-open #library-import-error[role='alert']"
           )

    refute has_element?(view, "#library-import-skipped p")
    assert Repo.aggregate(from(b in LibraryBlock, where: b.owner_id == ^user.id), :count) == 0
  end

  test "read permission alone cannot open or submit import even with forged events", %{conn: conn} do
    user = insert(:account, role: insert(:role, permissions: ["library.read"]))
    conn = init_test_session(conn, %{"account_id" => user.id})
    {:ok, view, _} = live(conn, ~p"/studio/library")
    refute has_element?(view, "#library-import-open")
    render_hook(view, "open_import", %{})
    render_hook(view, "import_questions", %{"import" => %{"format" => "gift"}})
    assert has_element?(view, "#library-import-error", "permission")
    assert Repo.aggregate(from(b in LibraryBlock, where: b.owner_id == ^user.id), :count) == 0
  end

  test "cancel removes pending uploads and missing files produce a readable error", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/studio/library")
    view |> element("#library-import-open") |> render_click()
    render_hook(view, "import_questions", %{"import" => %{"format" => "gift"}})
    assert has_element?(view, "#library-import-error", "Choose a file")
    view |> element("#library-import-modal .modal-backdrop") |> render_click()
    view |> element("#library-import-open") |> render_click()
    assert has_element?(view, "#library-import-submit[disabled]")
  end

  test "import preserves active list filters", %{conn: conn, user: user} do
    {:ok, view, _} = live(conn, ~p"/studio/library?search=NoMatch")
    view |> element("#library-import-open") |> render_click()
    upload(view, "questions.gift", "::Imported question::Question {}", "gift")
    assert has_element?(view, "#library-import-result", "Imported: 1")
    question = Repo.one!(from b in LibraryBlock, where: b.owner_id == ^user.id)
    refute has_element?(view, "#library_blocks-#{question.id}")
  end

  test "Russian locale translates import help and skipped-question reasons", %{conn: conn} do
    conn = init_test_session(conn, %{"locale" => "ru"})
    {:ok, view, _} = live(conn, ~p"/studio/library")
    view |> element("#library-import-open") |> render_click()
    assert has_element?(view, "#library-import-help", "Повторный импорт")
    upload(view, "questions.gift", "::Numerical::Value? {#2}", "gift")
    assert has_element?(view, "#library-import-result", "Импортировано: 0. Пропущено: 1.")
    assert has_element?(view, "#library-import-skipped", "Тип вопроса не поддерживается")
  end

  test "retrying after skipped questions replaces the previous outcome", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/studio/library")
    view |> element("#library-import-open") |> render_click()
    upload(view, "unsupported.gift", "::Numerical::Value? {#2}", "gift")
    assert has_element?(view, "#flash-error", "Imported: 0")

    view |> element("#library-import-open") |> render_click()
    upload(view, "questions.gift", "::Imported question::Question {}", "gift")
    refute has_element?(view, "#library-import-modal.modal-open")
    assert has_element?(view, "#flash-info", "Imported: 1. Skipped: 0.")
    refute has_element?(view, "#flash-error")
    refute has_element?(view, "#library-import-skipped p")
  end
end
