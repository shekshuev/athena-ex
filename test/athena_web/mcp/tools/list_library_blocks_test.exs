defmodule AthenaWeb.MCP.Tools.ListLibraryBlocksTest do
  use AthenaWeb.ConnCase, async: true

  alias AthenaWeb.MCP.Tools.{ListLibraryBlocks, CreateLibraryBlock, PinLibraryBlock}
  alias Athena.Content
  import Athena.Factory

  setup %{conn: conn} do
    owner =
      insert(:account,
        role:
          insert(:role,
            permissions: ["courses.create", "courses.update", "library.update", "library.read"]
          )
      )

    {:ok, course} = Content.create_course(owner, %{"title" => "Library course"})
    %{conn: assign(conn, :current_user, owner), course: course}
  end

  test "pinned_only=true only returns blocks pinned to that course", %{
    conn: conn,
    course: course
  } do
    created =
      CreateLibraryBlock.call(conn, %{
        "title" => "Reusable question",
        "type" => "quiz_question",
        "content" => %{
          "question_type" => "exact_match",
          "body" => %{"type" => "doc", "content" => []},
          "correct_answer" => "42"
        },
        "tags" => ["sql"]
      })

    library_block_id =
      created
      |> Map.fetch!("content")
      |> List.first()
      |> Map.fetch!("text")
      |> Jason.decode!()
      |> Map.fetch!("id")

    before_pin =
      ListLibraryBlocks.call(conn, %{"course_id" => course.id, "pinned_only" => true})
      |> Map.fetch!("content")
      |> List.first()
      |> Map.fetch!("text")
      |> Jason.decode!()

    refute library_block_id in Enum.map(before_pin["library_blocks"], & &1["id"])

    PinLibraryBlock.call(conn, %{"course_id" => course.id, "library_block_id" => library_block_id})

    after_pin =
      ListLibraryBlocks.call(conn, %{"course_id" => course.id, "pinned_only" => true})
      |> Map.fetch!("content")
      |> List.first()
      |> Map.fetch!("text")
      |> Jason.decode!()

    assert library_block_id in Enum.map(after_pin["library_blocks"], & &1["id"])
  end
end
