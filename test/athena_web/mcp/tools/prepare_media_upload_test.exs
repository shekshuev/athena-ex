defmodule AthenaWeb.MCP.Tools.PrepareMediaUploadTest do
  use AthenaWeb.ConnCase, async: true

  alias AthenaWeb.MCP.Tools.PrepareMediaUpload
  alias Athena.Content
  import Athena.Factory

  test "returns a presigned url and metadata when the account can edit the course", %{conn: conn} do
    owner =
      insert(:account, role: insert(:role, permissions: ["courses.create", "courses.update"]))

    {:ok, course} = Content.create_course(owner, %{"title" => "Media course"})
    conn = assign(conn, :current_user, owner)

    result =
      PrepareMediaUpload.call(conn, %{"course_id" => course.id, "filename" => "diagram.png"})

    assert %{"content" => [%{"type" => "text", "text" => text}]} = result
    meta = Jason.decode!(text)

    assert is_binary(meta["url"])
    assert meta["url_for_saved_entry"] == "/media/#{meta["key"]}"
    assert String.contains?(meta["key"], course.id)
  end

  test "returns an MCP error result for an account without course-edit rights", %{conn: conn} do
    owner = insert(:account, role: insert(:role, permissions: ["courses.create"]))
    {:ok, course} = Content.create_course(owner, %{"title" => "Someone else's media course"})

    outsider = insert(:account, role: insert(:role, permissions: []))
    conn = assign(conn, :current_user, outsider)

    result =
      PrepareMediaUpload.call(conn, %{"course_id" => course.id, "filename" => "diagram.png"})

    assert %{"content" => _content, "isError" => true} = result
  end

  test "allows a \"submission\" upload for any authenticated account", %{conn: conn} do
    owner = insert(:account, role: insert(:role, permissions: ["courses.create"]))
    {:ok, course} = Content.create_course(owner, %{"title" => "Submission course"})

    student = insert(:account, role: insert(:role, permissions: []))
    conn = assign(conn, :current_user, student)

    result =
      PrepareMediaUpload.call(conn, %{
        "course_id" => course.id,
        "filename" => "homework.zip",
        "upload_context" => "submission"
      })

    assert %{"content" => [%{"type" => "text", "text" => _text}]} = result
  end
end
