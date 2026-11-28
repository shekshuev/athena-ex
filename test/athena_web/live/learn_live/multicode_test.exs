defmodule AthenaWeb.LearnLive.MulticodeTest do
  use AthenaWeb.ConnCase, async: true
  use Oban.Testing, repo: Athena.Repo

  import Phoenix.LiveViewTest
  import Athena.Factory
  import Ecto.Query
  alias Athena.{Content, Learning, Repo}

  setup %{conn: conn} do
    user = insert(:account)
    course = insert(:course)
    insert(:enrollment, account_id: user.id, course_id: course.id)
    section = insert(:section, course: course)

    ready = fn template, secret ->
      %{
        "initial_code" => template,
        "solution_code" => secret,
        "test_cases" => [
          %{"expected_output" => "SECRET_OUTPUT", "is_hidden" => true, "weight" => 100}
        ]
      }
    end

    block =
      insert(:block,
        section: section,
        type: :multicode,
        content: %{
          "active_language" => "c",
          "languages" => %{
            "python3" => ready.("python template", "SECRET_PYTHON"),
            "javascript" => ready.("js template", "SECRET_JS"),
            "c" => %{"initial_code" => "UNREADY_C"}
          }
        }
      )

    %{
      conn: init_test_session(conn, %{"account_id" => user.id}),
      user: user,
      course: course,
      section: section,
      block: block
    }
  end

  test "student tabs hide incomplete variants and preserve drafts across switches and reload",
       ctx do
    path = ~p"/learn/courses/#{ctx.course.id}/play/#{ctx.section.id}"
    {:ok, view, _} = live(ctx.conn, path)
    id = ctx.block.id
    assert has_element?(view, "#multicode-tab-editor-#{id}-python3[aria-selected=true]")
    assert has_element?(view, "#multicode-tab-editor-#{id}-javascript")
    refute has_element?(view, "#multicode-tab-editor-#{id}-c")
    refute has_element?(view, "[data-code*=SECRET]")
    refute has_element?(view, "[name*=solution_code]")

    render_hook(view, "select_code_language", %{
      "block_id" => id,
      "language" => "javascript",
      "code" => "python draft"
    })

    assert has_element?(view, "input[data-code-block-id='#{id}'][value='js template']")

    render_hook(view, "select_code_language", %{
      "block_id" => id,
      "language" => "python3",
      "code" => "js draft"
    })

    assert has_element?(view, "input[data-code-block-id='#{id}'][value='python draft']")
    {:ok, reloaded, _} = live(ctx.conn, path)
    assert has_element?(reloaded, "input[data-code-block-id='#{id}'][value='python draft']")
    assert Learning.get_draft(ctx.user.id, id)["language_drafts"]["javascript"] == "js draft"

    render_hook(reloaded, "select_code_language", %{
      "block_id" => id,
      "language" => "c",
      "code" => "ignore"
    })

    assert has_element?(reloaded, "#multicode-tab-editor-#{id}-python3[aria-selected=true]")
  end

  test "test run and formal submission use existing execution workers with selected language",
       ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/learn/courses/#{ctx.course.id}/play/#{ctx.section.id}")
    id = ctx.block.id

    render_hook(view, "select_code_language", %{
      "block_id" => id,
      "language" => "javascript",
      "code" => "py"
    })

    view |> element("button[phx-click=run_code][phx-value-block_id='#{id}']") |> render_click()
    assert_enqueued(worker: Athena.Execution.TestWorker)

    render_hook(view, "submit_code", %{
      "block_id" => id,
      "answer" => %{"code" => "console.log(1)", "language" => "javascript"}
    })

    assert_enqueued(worker: Athena.Execution.Worker)
    submission = Repo.one!(from(s in Athena.Learning.Submission, where: s.block_id == ^id))
    assert submission.content["language"] == "javascript"
    assert submission.content["code"] == "console.log(1)"
  end

  test "forged unavailable languages are rejected by Learning", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/learn/courses/#{ctx.course.id}/play/#{ctx.section.id}")

    for language <- ["sql", "c", "missing"] do
      content = %{"type" => "multicode", "code" => "untrusted", "language" => language}
      render_hook(view, "submit_code", %{"block_id" => ctx.block.id, "answer" => content})

      assert {:error, _} =
               Learning.create_submission(ctx.user, %{
                 "block_id" => ctx.block.id,
                 "content" => content
               })

      assert {:error, :unavailable_language} =
               Learning.save_draft(ctx.user, ctx.block.id, content)

      assert {:error, :unavailable_language} =
               Content.code_challenge(:multicode, ctx.block.content, language)
    end

    refute_enqueued(worker: Athena.Execution.Worker)
  end
end
