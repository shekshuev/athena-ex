defmodule AthenaWeb.StudioLive.MulticodeTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Athena.Factory
  alias Athena.{Content, Repo}

  test "teacher adds variants and edits reference, limits and tests independently", %{conn: conn} do
    role = insert(:role, permissions: ["courses.update", "admin"])
    teacher = insert(:account, role: role)
    course = insert(:course, owner_id: teacher.id)
    section = insert(:section, course: course)
    conn = init_test_session(conn, %{"account_id" => teacher.id})
    {:ok, view, _} = live(conn, ~p"/studio/courses/#{course.id}/builder/sections/#{section.id}")
    render_click(view, "add_multicode_block", %{})
    [block] = Content.list_blocks_by_section(section.id)
    assert block.type == :multicode
    id = block.id
    assert has_element?(view, "#multicode-tab-editor-#{id}-python3")
    refute has_element?(view, "#multicode-tab-editor-#{id}-sql")
    view |> element("button[phx-click=add_test_case][phx-value-id='#{id}']") |> render_click()
    block = Repo.get!(Athena.Content.Block, id)
    assert length(block.content["languages"]["python3"]["test_cases"]) == 1

    render_change(view, "update_block_meta", %{
      "block" => %{
        "id" => id,
        "content" => %{
          "active_language" => "python3",
          "solution_code" => "print(1)",
          "test_cases" => %{"0" => %{"expected_output" => "1", "weight" => "100"}}
        }
      }
    })

    render_click(view, "select_multicode_language", %{"id" => id, "language" => "javascript"})
    assert has_element?(view, "#multicode-tab-editor-#{id}-javascript[aria-selected=true]")
    refute has_element?(view, "#solution-input-#{id}[value='print(1)']")

    render_change(view, "update_block_meta", %{
      "block" => %{
        "id" => id,
        "content" => %{
          "active_language" => "javascript",
          "solution_code" => "console.log(1)"
        }
      }
    })

    view
    |> form("#block-inspector-form-#{id}", block: %{content: %{time_limit: 3}})
    |> render_change()

    render_click(view, "select_multicode_language", %{"id" => id, "language" => "python3"})
    assert has_element?(view, "#solution-input-#{id}[value='print(1)']")
    block = Repo.get!(Athena.Content.Block, id)
    assert block.content["languages"]["python3"]["time_limit"] == 1.0
    assert block.content["languages"]["javascript"]["time_limit"] == 3.0
    assert Enum.map(Content.multicode_options(block.content), &elem(&1, 1)) == ["python3"]
  end

  test "library templates expose the same author tabs and variant settings", %{conn: conn} do
    role = insert(:role, permissions: ["admin", "library.read", "library.update"])
    teacher = insert(:account, role: role)

    block =
      insert(:library_block,
        owner_id: teacher.id,
        type: :multicode,
        content: %{"active_language" => "python3", "languages" => %{"python3" => %{}}}
      )

    conn = init_test_session(conn, %{"account_id" => teacher.id})
    {:ok, view, _} = live(conn, ~p"/studio/library/#{block.id}/editor")
    assert has_element?(view, "#multicode-tab-editor-#{block.id}-python3")

    render_click(view, "select_multicode_language", %{
      "id" => block.id,
      "language" => "javascript"
    })

    assert has_element?(view, "#multicode-tab-editor-#{block.id}-javascript[aria-selected=true]")

    render_change(view, "update_block_meta", %{
      "block" => %{"id" => block.id, "content" => %{"solution_code" => "console.log(1)"}}
    })

    stored = Repo.get!(Athena.Content.LibraryBlock, block.id)
    assert stored.content["languages"]["javascript"]["solution_code"] == "console.log(1)"
    assert stored.content["languages"]["python3"]["solution_code"] == ""
  end
end
