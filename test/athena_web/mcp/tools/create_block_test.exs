defmodule AthenaWeb.MCP.Tools.CreateBlockTest do
  use AthenaWeb.ConnCase, async: true

  alias AthenaWeb.MCP.Tools.{CreateBlock, UpdateBlock}
  alias Athena.Content
  import Athena.Factory

  setup %{conn: conn} do
    owner =
      insert(:account, role: insert(:role, permissions: ["courses.create", "courses.update"]))

    {:ok, course} = Content.create_course(owner, %{"title" => "Rules course"})

    {:ok, section} =
      Content.create_section(owner, %{"course_id" => course.id, "title" => "Intro"})

    %{conn: assign(conn, :current_user, owner), section: section}
  end

  test "sets completion_rule and access_rules on creation", %{conn: conn, section: section} do
    result =
      CreateBlock.call(conn, %{
        "section_id" => section.id,
        "type" => "text",
        "content" => %{"type" => "doc", "content" => []},
        "completion_rule" => %{"type" => "button", "button_text" => "Continue"},
        "access_rules" => %{"reset_waterline" => true}
      })

    assert %{"content" => [%{"type" => "text", "text" => text}]} = result
    block = Jason.decode!(text)

    assert block["completion_rule"] == %{
             "type" => "button",
             "button_text" => "Continue",
             "min_score" => nil
           }

    assert block["access_rules"] == %{
             "unlock_at" => nil,
             "lock_at" => nil,
             "reset_waterline" => true
           }
  end

  test "update_block replaces completion_rule instead of merging with the previous one", %{
    conn: conn,
    section: section
  } do
    created =
      CreateBlock.call(conn, %{
        "section_id" => section.id,
        "type" => "text",
        "content" => %{"type" => "doc", "content" => []},
        "completion_rule" => %{"type" => "button", "button_text" => "Continue"}
      })

    block_id =
      created
      |> Map.fetch!("content")
      |> List.first()
      |> Map.fetch!("text")
      |> Jason.decode!()
      |> Map.fetch!("id")

    updated =
      UpdateBlock.call(conn, %{
        "block_id" => block_id,
        "completion_rule" => %{"type" => "pass_auto_grade", "min_score" => 80}
      })

    assert %{"content" => [%{"type" => "text", "text" => text}]} = updated
    block = Jason.decode!(text)

    # Without RuleAttrs normalizing this payload, `embeds_one ..., on_replace:
    # :update` would leave the stale button_text: "Continue" in place.
    assert block["completion_rule"] == %{
             "type" => "pass_auto_grade",
             "button_text" => nil,
             "min_score" => 80
           }
  end
end
