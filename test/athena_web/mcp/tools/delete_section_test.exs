defmodule AthenaWeb.MCP.Tools.DeleteSectionTest do
  use AthenaWeb.ConnCase, async: true

  alias AthenaWeb.MCP.Tools.DeleteSection
  alias Athena.Content
  import Athena.Factory

  test "deletes a section the account can edit", %{conn: conn} do
    owner =
      insert(:account, role: insert(:role, permissions: ["courses.create", "courses.update"]))

    {:ok, course} = Content.create_course(owner, %{"title" => "Course for deletion"})

    {:ok, section} =
      Content.create_section(owner, %{"course_id" => course.id, "title" => "Intro"})

    section_id = section.id
    conn = assign(conn, :current_user, owner)
    result = DeleteSection.call(conn, %{"section_id" => section_id})

    assert %{"content" => [%{"type" => "text", "text" => text}]} = result
    assert %{"id" => ^section_id} = Jason.decode!(text)
    assert {:error, :not_found} = Content.get_section(owner, section_id)
  end

  test "returns an MCP error result (not a crash) for a section the account can't edit", %{
    conn: conn
  } do
    owner =
      insert(:account, role: insert(:role, permissions: ["courses.create", "courses.update"]))

    {:ok, course} = Content.create_course(owner, %{"title" => "Someone else's course"})

    {:ok, section} =
      Content.create_section(owner, %{"course_id" => course.id, "title" => "Intro"})

    outsider = insert(:account, role: insert(:role, permissions: []))
    conn = assign(conn, :current_user, outsider)

    result = DeleteSection.call(conn, %{"section_id" => section.id})

    assert %{"content" => _content, "isError" => true} = result
    assert {:ok, _} = Content.get_section(owner, section.id)
  end

  test "returns an MCP error result for an unknown section_id", %{conn: conn} do
    account = insert(:account, role: insert(:role, permissions: ["courses.update"]))
    conn = assign(conn, :current_user, account)

    result = DeleteSection.call(conn, %{"section_id" => Ecto.UUID.generate()})

    assert %{"content" => _content, "isError" => true} = result
  end
end
