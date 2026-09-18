defmodule AthenaWeb.MCP.Tools.CreateCourseTest do
  use AthenaWeb.ConnCase, async: true

  alias AthenaWeb.MCP.Tools.CreateCourse
  import Athena.Factory

  test "creates a course when the account has courses.create", %{conn: conn} do
    account = insert(:account, role: insert(:role, permissions: ["courses.create"]))
    conn = assign(conn, :current_user, account)

    result = CreateCourse.call(conn, %{"title" => "My New Course"})

    assert %{"content" => [%{"type" => "text", "text" => text}]} = result
    assert %{"title" => "My New Course"} = Jason.decode!(text)
  end

  test "returns an MCP error result (not a crash) when forbidden", %{conn: conn} do
    account = insert(:account, role: insert(:role, permissions: []))
    conn = assign(conn, :current_user, account)

    result = CreateCourse.call(conn, %{"title" => "My New Course"})

    assert %{"content" => _content, "isError" => true} = result
  end
end
