defmodule AthenaWeb.MCP.Tools.AttachMediaToBlockTest do
  use AthenaWeb.ConnCase, async: true

  alias AthenaWeb.MCP.Tools.AttachMediaToBlock
  alias Athena.Content
  import Athena.Factory

  setup %{conn: conn} do
    owner =
      insert(:account, role: insert(:role, permissions: ["courses.create", "courses.update"]))

    {:ok, course} = Content.create_course(owner, %{"title" => "Attach course"})

    {:ok, section} =
      Content.create_section(owner, %{"course_id" => course.id, "title" => "Intro"})

    {:ok, block} =
      Content.create_block(owner, %{
        "section_id" => section.id,
        "type" => "image",
        "content" => %{"alt" => "placeholder"}
      })

    %{conn: assign(conn, :current_user, owner), block: block}
  end

  test "sets content.url while preserving other content keys", %{conn: conn, block: block} do
    result =
      AttachMediaToBlock.call(conn, %{
        "block_id" => block.id,
        "bucket" => "athena-test",
        "key" => "courses/#{block.section_id}/uuid-diagram.png",
        "url_for_saved_entry" => "/media/courses/#{block.section_id}/uuid-diagram.png",
        "name" => "diagram.png",
        "type" => "image/png",
        "size" => 1234
      })

    assert %{"content" => [%{"type" => "text", "text" => text}]} = result
    updated = Jason.decode!(text)

    assert updated["content"]["url"] == "/media/courses/#{block.section_id}/uuid-diagram.png"
    assert updated["content"]["alt"] == "placeholder"
  end

  test "returns an MCP error result for an account without edit rights on the section", %{
    block: block,
    conn: conn
  } do
    outsider = insert(:account, role: insert(:role, permissions: []))
    conn = assign(conn, :current_user, outsider)

    result =
      AttachMediaToBlock.call(conn, %{
        "block_id" => block.id,
        "bucket" => "b",
        "key" => "k",
        "url_for_saved_entry" => "/media/k",
        "name" => "n",
        "type" => "t",
        "size" => 1
      })

    assert %{"content" => _content, "isError" => true} = result
  end

  test "returns an MCP error result for an unknown block_id", %{conn: conn} do
    result =
      AttachMediaToBlock.call(conn, %{
        "block_id" => Ecto.UUID.generate(),
        "bucket" => "b",
        "key" => "k",
        "url_for_saved_entry" => "/media/k",
        "name" => "n",
        "type" => "t",
        "size" => 1
      })

    assert %{"content" => _content, "isError" => true} = result
  end
end
