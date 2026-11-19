defmodule AthenaWeb.LibraryExportControllerTest do
  use AthenaWeb.ConnCase, async: true
  import Athena.Factory

  alias Athena.{Content, Repo}

  setup %{conn: conn} do
    role =
      insert(:role,
        permissions: ["library.read", "courses.read"],
        policies: %{"library.read" => ["own_only"], "courses.read" => ["own_only"]}
      )

    user = insert(:account, role: role)
    %{conn: init_test_session(conn, %{"account_id" => user.id}), user: user}
  end

  defp question(attrs) do
    insert(
      :library_block,
      Keyword.merge(
        [
          type: :quiz_question,
          content: %{
            "question_type" => "exact_match",
            "body" => %{
              "type" => "doc",
              "content" => [
                %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "Answer?"}]}
              ]
            },
            "correct_answer" => "Lua",
            "case_sensitive" => true
          }
        ],
        attrs
      )
    )
  end

  test "a reader can download all filtered questions across pages in both formats", %{
    conn: conn,
    user: user
  } do
    question(owner_id: user.id, title: "Lecture one", tags: ["nosql", "lecture"])
    question(owner_id: user.id, title: "Lecture two", tags: ["nosql", "lecture"])
    question(owner_id: user.id, title: "Other", tags: ["nosql"])
    question(title: "Lecture secret", tags: ["nosql", "lecture"])
    insert(:library_block, owner_id: user.id, title: "Lecture notes", tags: ["nosql", "lecture"])

    params = %{
      "scope" => "filtered",
      "search" => "Lecture",
      "tag" => "nosql, lecture",
      "page_size" => "1",
      "page" => "2"
    }

    assert {:ok, %{total: 3, questions: 2, skipped: 1}} =
             Content.preview_library_export(user, params)

    for format <- ["gift", "moodle_xml"] do
      response_conn = post(conn, ~p"/studio/library/export", Map.put(params, "format", format))
      body = response(response_conn, 200)
      assert body =~ "Lecture one"
      assert body =~ "Lecture two"
      refute body =~ "Lecture notes"
      refute body =~ "Lecture secret"
      assert [disposition] = get_resp_header(response_conn, "content-disposition")
      assert disposition =~ "attachment"
      assert get_resp_header(response_conn, "cache-control") == ["no-store"]
    end
  end

  test "explicit selection includes only selected questions and reports other block types", %{
    conn: conn,
    user: user
  } do
    q = question(owner_id: user.id)
    text = insert(:library_block, owner_id: user.id)
    question(owner_id: user.id, title: "Not selected")
    params = %{"scope" => "selected", "ids" => [q.id, text.id], "format" => "gift"}

    assert {:ok, %{total: 2, questions: 1, skipped: 1}} =
             Content.preview_library_export(user, params)

    body = conn |> post(~p"/studio/library/export", params) |> response(200)
    assert body =~ q.title
    refute body =~ "Not selected"

    assert conn
           |> post(~p"/studio/library/export", %{params | "ids" => [text.id]})
           |> response(422)
  end

  test "forged IDs and revoked sharing cannot export private questions", %{conn: conn, user: user} do
    private = question([])
    params = %{"scope" => "selected", "ids" => [private.id], "format" => "moodle_xml"}
    assert conn |> post(~p"/studio/library/export", params) |> response(403)

    share =
      insert(:library_block_share, library_block: private, account_id: user.id, role: :reader)

    assert conn |> post(~p"/studio/library/export", params) |> response(200)
    Repo.delete!(share)
    assert conn |> post(~p"/studio/library/export", params) |> response(403)
  end

  test "public questions and reader shares use the same access rules as the list", %{
    conn: conn,
    user: user
  } do
    public = question(is_public: true)
    shared = question([])
    insert(:library_block_share, library_block: shared, account_id: user.id, role: :reader)
    params = %{"scope" => "selected", "ids" => [public.id, shared.id], "format" => "gift"}
    assert conn |> post(~p"/studio/library/export", params) |> response(200)
  end

  test "the browser form's nested scope and format are honored with an empty course field", %{
    conn: conn,
    user: user
  } do
    q = question(owner_id: user.id)

    conn =
      post(conn, ~p"/studio/library/export", %{
        "export" => %{"scope" => "selected", "format" => "moodle_xml"},
        "ids" => [q.id],
        "course_id" => "",
        "pinned_only" => "false"
      })

    assert response(conn, 200) =~ "<usecase>1</usecase>"
    assert response_content_type(conn, :xml)
  end

  test "course-bank access is granted only through a readable course", %{conn: conn, user: user} do
    course = insert(:course, owner_id: user.id)
    private = question([])
    insert(:course_library_block, course: course, library_block: private)

    params = %{
      "scope" => "filtered",
      "course_id" => course.id,
      "pinned_only" => "true",
      "format" => "gift"
    }

    assert conn |> post(~p"/studio/library/export", params) |> response(200)
    stranger_course = insert(:course)
    insert(:course_library_block, course: stranger_course, library_block: private)

    assert conn
           |> post(~p"/studio/library/export", %{params | "course_id" => stranger_course.id})
           |> response(403)
  end

  test "permission, authentication, account status and password-change gates apply to downloads",
       %{conn: conn} do
    for attrs <- [
          [role: insert(:role, permissions: [])],
          [status: :blocked],
          [must_change_password: true]
        ] do
      user = insert(:account, attrs)
      conn = init_test_session(conn, %{"account_id" => user.id})

      assert conn
             |> post(~p"/studio/library/export", %{"scope" => "filtered", "format" => "gift"})
             |> response(403)
    end

    conn = conn |> clear_session() |> init_test_session(%{})

    assert conn
           |> post(~p"/studio/library/export", %{"scope" => "filtered", "format" => "gift"})
           |> response(403)
  end

  test "empty selection, invalid IDs, invalid format and unsupported question content are handled",
       %{conn: conn, user: user} do
    params = %{"scope" => "selected", "ids" => [], "format" => "gift"}
    assert conn |> post(~p"/studio/library/export", params) |> response(422)

    assert conn
           |> post(~p"/studio/library/export", %{params | "ids" => ["bad-id"]})
           |> response(400)

    assert conn
           |> post(~p"/studio/library/export", %{params | "format" => "unknown"})
           |> response(400)

    q =
      question(
        owner_id: user.id,
        content: %{"question_type" => "single", "body" => %{"type" => "doc"}, "options" => []}
      )

    assert conn |> post(~p"/studio/library/export", %{params | "ids" => [q.id]}) |> response(422)

    assert conn
           |> post(~p"/studio/library/export", %{
             "scope" => "filtered",
             "format" => "gift",
             "tag" => ["nosql"]
           })
           |> response(400)

    assert conn |> post(~p"/studio/library/export", %{"export" => ["gift"]}) |> response(400)
  end
end
