defmodule AthenaWeb.StudioLive.BuilderTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory
  alias Athena.{Content, Repo}
  alias Athena.Content.{LibraryBlock, CourseLibraryBlock}

  setup %{conn: conn} do
    role = insert(:role, permissions: ["courses.update", "admin"])
    admin = insert(:account, role: role)

    conn = init_test_session(conn, %{"account_id" => admin.id})

    course = insert(:course, owner_id: admin.id)

    %{conn: conn, admin: admin, course: course}
  end

  describe "Mount & Access" do
    test "redirects if course does not exist", %{conn: conn} do
      fake_id = Ecto.UUID.generate()

      assert {:error, {:live_redirect, %{to: "/studio/courses"}}} =
               live(conn, ~p"/studio/courses/#{fake_id}/builder")
    end

    test "renders builder successfully", %{conn: conn, course: course} do
      {:ok, _lv, html} = live(conn, ~p"/studio/courses/#{course.id}/builder")

      assert html =~ "No sections yet. Create your first one!"
    end
  end

  describe "Section Management" do
    test "adds a new root section", %{conn: conn, course: course} do
      {:ok, lv, _html} = live(conn, ~p"/studio/courses/#{course.id}/builder")

      lv
      |> element("button[phx-click='add_section']")
      |> render_click()

      assert render(lv) =~ "New Lesson"

      tree = Content.get_course_tree(course.id)
      assert length(tree) == 1
      assert hd(tree).title == "New Lesson"
    end

    test "selects a section and opens it in inspector", %{
      conn: conn,
      course: course,
      admin: admin
    } do
      {:ok, section} =
        Content.create_section(admin, %{
          "title" => "My Awesome Lesson",
          "course_id" => course.id,
          "owner_id" => admin.id
        })

      {:ok, lv, _html} = live(conn, ~p"/studio/courses/#{course.id}/builder")

      lv
      |> element("div[phx-click='select_section'][phx-value-id='#{section.id}']")
      |> render_click()

      html = render(lv)
      assert html =~ "My Awesome Lesson"
      assert html =~ "Section Title"
      assert html =~ "Access &amp; Visibility"
    end

    test "deletes a section via modal", %{conn: conn, course: course, admin: admin} do
      {:ok, section} =
        Content.create_section(admin, %{
          "title" => "To Be Deleted",
          "course_id" => course.id,
          "owner_id" => admin.id
        })

      {:ok, lv, _html} = live(conn, ~p"/studio/courses/#{course.id}/builder")

      lv
      |> element("div[phx-click='select_section'][phx-value-id='#{section.id}']")
      |> render_click()

      lv |> element("button[phx-click='delete_section_click']") |> render_click()

      lv |> element("#delete-section-modal button", "Delete") |> render_click()

      html = render(lv)
      refute html =~ "To Be Deleted"
      assert Content.get_course_tree(course.id) == []
    end

    test "updates section metadata via inspector form", %{
      conn: conn,
      course: course,
      admin: admin
    } do
      {:ok, section} =
        Content.create_section(admin, %{
          "title" => "Old Title",
          "course_id" => course.id,
          "owner_id" => admin.id
        })

      {:ok, lv, _html} = live(conn, ~p"/studio/courses/#{course.id}/builder")

      lv
      |> element("div[phx-click='select_section'][phx-value-id='#{section.id}']")
      |> render_click()

      lv
      |> form("#section-inspector-form-#{section.id}", %{
        "section" => %{"title" => "Updated Title"}
      })
      |> render_change()

      assert render(lv) =~ "Updated Title"

      {:ok, updated_section} = Content.get_section(section.id)
      assert updated_section.title == "Updated Title"
    end

    test "saves engagement_rule thresholds set on a section", %{
      conn: conn,
      course: course,
      admin: admin
    } do
      {:ok, section} =
        Content.create_section(admin, %{
          "title" => "Week 1",
          "course_id" => course.id,
          "owner_id" => admin.id
        })

      {:ok, lv, _html} = live(conn, ~p"/studio/courses/#{course.id}/builder")

      lv
      |> element("div[phx-click='select_section'][phx-value-id='#{section.id}']")
      |> render_click()

      lv
      |> form("#section-inspector-form-#{section.id}", %{
        "section" => %{
          "engagement_rule" => %{"expected_seconds" => "120", "nudge_enabled" => "false"}
        }
      })
      |> render_change()

      {:ok, updated_section} = Content.get_section(section.id)
      assert updated_section.engagement_rule.expected_seconds == 120
      assert updated_section.engagement_rule.nudge_enabled == false
    end

    test "saves engagement_rule thresholds set on a block", %{
      conn: conn,
      course: course,
      admin: admin
    } do
      {:ok, section} =
        Content.create_section(admin, %{
          "title" => "Week 1",
          "course_id" => course.id,
          "owner_id" => admin.id
        })

      {:ok, block} =
        Content.create_block(admin, %{
          "type" => "text",
          "content" => %{"text" => "Hello"},
          "section_id" => section.id
        })

      {:ok, lv, _html} = live(conn, ~p"/studio/courses/#{course.id}/builder")

      lv
      |> element("div[phx-click='select_section'][phx-value-id='#{section.id}']")
      |> render_click()

      lv
      |> element("div[phx-click='select_block'][phx-value-id='#{block.id}']")
      |> render_click()

      lv
      |> form("#block-inspector-form-#{block.id}", %{
        "block" => %{
          "engagement_rule" => %{
            "expected_seconds" => "60",
            "fast_ratio_threshold" => "0.3",
            "nudge_enabled" => "true"
          }
        }
      })
      |> render_change()

      {:ok, updated_block} = Content.get_block(block.id)
      assert updated_block.engagement_rule.expected_seconds == 60
      assert updated_block.engagement_rule.fast_ratio_threshold == 0.3
      assert updated_block.engagement_rule.nudge_enabled == true
    end
  end

  describe "Block Management (UI Actions)" do
    setup %{course: course, admin: admin} do
      {:ok, section} =
        Content.create_section(admin, %{
          "title" => "Complex Blocks",
          "course_id" => course.id
        })

      %{section: section}
    end

    test "adds a text block to active section", %{conn: conn, course: course, section: section} do
      {:ok, lv, _html} = live(conn, ~p"/studio/courses/#{course.id}/builder")

      lv
      |> element("div[phx-click='select_section'][phx-value-id='#{section.id}']")
      |> render_click()

      lv |> element("button[phx-click='add_text_block']") |> render_click()

      html = render(lv)
      assert html =~ "tiptap-"

      blocks = Content.list_blocks_by_section(section.id)
      assert length(blocks) == 1
      assert hd(blocks).type == :text
    end

    test "deletes a block via modal", %{
      conn: conn,
      course: course,
      section: section,
      admin: admin
    } do
      {:ok, block} =
        Content.create_block(admin, %{
          "type" => "text",
          "section_id" => section.id,
          "content" => %{}
        })

      {:ok, lv, _html} = live(conn, ~p"/studio/courses/#{course.id}/builder")

      lv
      |> element("div[phx-click='select_section'][phx-value-id='#{section.id}']")
      |> render_click()

      lv |> element("div[phx-click='select_block'][phx-value-id='#{block.id}']") |> render_click()

      lv |> element("button[phx-click='delete_block_click']") |> render_click()

      render_hook(lv, "confirm_delete_block")

      blocks = Content.list_blocks_by_section(section.id)
      assert blocks == []
    end

    test "copies a block, inserting the duplicate immediately after it", %{
      conn: conn,
      course: course,
      section: section,
      admin: admin
    } do
      {:ok, block} =
        Content.create_block(admin, %{
          "type" => "text",
          "section_id" => section.id,
          "content" => %{"type" => "doc", "content" => [%{"type" => "paragraph"}]},
          "visibility" => "hidden"
        })

      {:ok, other} =
        Content.create_block(admin, %{
          "type" => "text",
          "section_id" => section.id,
          "content" => %{"type" => "doc", "content" => [%{"type" => "paragraph"}]}
        })

      {:ok, lv, _html} = live(conn, ~p"/studio/courses/#{course.id}/builder")

      lv
      |> element("div[phx-click='select_section'][phx-value-id='#{section.id}']")
      |> render_click()

      lv |> element("div[phx-click='select_block'][phx-value-id='#{block.id}']") |> render_click()

      lv
      |> element("button[phx-click='copy_block'][phx-value-id='#{block.id}']")
      |> render_click()

      blocks = Content.list_blocks_by_section(section.id)
      assert length(blocks) == 3

      [first, copy, last] = blocks
      assert first.id == block.id
      assert last.id == other.id

      refute copy.id == block.id
      assert copy.type == :text
      assert copy.content == block.content
      assert copy.visibility == :hidden
    end

    test "adds an image block to active section", %{conn: conn, course: course, section: section} do
      {:ok, lv, _html} = live(conn, ~p"/studio/courses/#{course.id}/builder")

      lv
      |> element("div[phx-click='select_section'][phx-value-id='#{section.id}']")
      |> render_click()

      lv |> element("button[phx-click='add_image_block']") |> render_click()

      blocks = Content.list_blocks_by_section(section.id)
      assert length(blocks) == 1
      assert hd(blocks).type == :image
    end

    test "adds a video block to active section", %{conn: conn, course: course, section: section} do
      {:ok, lv, _html} = live(conn, ~p"/studio/courses/#{course.id}/builder")

      lv
      |> element("div[phx-click='select_section'][phx-value-id='#{section.id}']")
      |> render_click()

      lv |> element("button[phx-click='add_video_block']") |> render_click()

      blocks = Content.list_blocks_by_section(section.id)
      assert length(blocks) == 1
      assert hd(blocks).type == :video
    end

    test "adds an attachment block to active section", %{
      conn: conn,
      course: course,
      section: section
    } do
      {:ok, lv, _html} = live(conn, ~p"/studio/courses/#{course.id}/builder")

      lv
      |> element("div[phx-click='select_section'][phx-value-id='#{section.id}']")
      |> render_click()

      lv |> element("button[phx-click='add_attachment_block']") |> render_click()

      blocks = Content.list_blocks_by_section(section.id)
      assert length(blocks) == 1
      assert hd(blocks).type == :attachment
    end

    test "adds a code block to active section", %{conn: conn, course: course, section: section} do
      {:ok, lv, _html} = live(conn, ~p"/studio/courses/#{course.id}/builder")

      lv
      |> element("div[phx-click='select_section'][phx-value-id='#{section.id}']")
      |> render_click()

      lv |> element("button[phx-click='add_code_block']") |> render_click()

      blocks = Content.list_blocks_by_section(section.id)
      assert length(blocks) == 1
      assert hd(blocks).type == :code
    end

    test "adds a quiz question block to active section", %{
      conn: conn,
      course: course,
      section: section
    } do
      {:ok, lv, _html} = live(conn, ~p"/studio/courses/#{course.id}/builder")

      lv
      |> element("div[phx-click='select_section'][phx-value-id='#{section.id}']")
      |> render_click()

      lv |> element("button[phx-click='add_quiz_question_block']") |> render_click()

      blocks = Content.list_blocks_by_section(section.id)
      assert length(blocks) == 1

      block = hd(blocks)
      assert block.type == :quiz_question
      assert block.content["question_type"] == "open"
    end

    test "adds a ticket exam block to active section", %{
      conn: conn,
      course: course,
      section: section
    } do
      {:ok, lv, _html} = live(conn, ~p"/studio/courses/#{course.id}/builder")

      lv
      |> element("div[phx-click='select_section'][phx-value-id='#{section.id}']")
      |> render_click()

      lv |> element("button[phx-click='add_ticket_exam_block']") |> render_click()

      blocks = Content.list_blocks_by_section(section.id)
      assert length(blocks) == 1

      block = hd(blocks)
      assert block.type == :ticket_exam
      assert block.content["slots"] == []
    end

    test "can reorder blocks via move_block_up and move_block_down", %{
      conn: conn,
      course: course,
      section: section,
      admin: admin
    } do
      {:ok, block1} = Content.create_block(admin, %{"type" => "text", "section_id" => section.id})
      {:ok, block2} = Content.create_block(admin, %{"type" => "text", "section_id" => section.id})

      {:ok, lv, _html} = live(conn, ~p"/studio/courses/#{course.id}/builder")

      lv
      |> element("div[phx-click='select_section'][phx-value-id='#{section.id}']")
      |> render_click()

      lv
      |> element("button[phx-click='move_block_up'][phx-value-id='#{block2.id}']")
      |> render_click()

      blocks = Content.list_blocks_by_section(section.id)
      assert Enum.at(blocks, 0).id == block2.id
      assert Enum.at(blocks, 1).id == block1.id

      lv
      |> element("button[phx-click='move_block_down'][phx-value-id='#{block2.id}']")
      |> render_click()

      blocks_after = Content.list_blocks_by_section(section.id)
      assert Enum.at(blocks_after, 0).id == block1.id
      assert Enum.at(blocks_after, 1).id == block2.id
    end

    test "deselects block via click-away", %{
      conn: conn,
      course: course,
      section: section,
      admin: admin
    } do
      {:ok, block} = Content.create_block(admin, %{"type" => "text", "section_id" => section.id})

      {:ok, lv, _html} = live(conn, ~p"/studio/courses/#{course.id}/builder")

      lv
      |> element("div[phx-click='select_section'][phx-value-id='#{section.id}']")
      |> render_click()

      lv
      |> element("div[phx-click='select_block'][phx-value-id='#{block.id}']")
      |> render_click()

      assert render(lv) =~ "Progression Rules"
      render_hook(lv, "deselect_block")
      refute render(lv) =~ "Progression Rules"
    end
  end

  describe "Quiz & Media Inspectors" do
    setup %{course: course, admin: admin} do
      {:ok, section} =
        Content.create_section(admin, %{
          "title" => "Complex Blocks",
          "course_id" => course.id,
          "owner_id" => admin.id
        })

      %{section: section}
    end

    test "updates quiz block options via canvas form", %{
      conn: conn,
      course: course,
      section: section,
      admin: admin
    } do
      {:ok, block} =
        Content.create_block(admin, %{
          "type" => "quiz_question",
          "section_id" => section.id,
          "content" => %{
            "question_type" => "single",
            "body" => %{},
            "options" => [
              %{
                "id" => "opt1",
                "text" => %{
                  "type" => "doc",
                  "content" => [
                    %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "A"}]}
                  ]
                },
                "is_correct" => false,
                "explanation" => ""
              }
            ]
          }
        })

      {:ok, lv, _html} = live(conn, ~p"/studio/courses/#{course.id}/builder")

      lv
      |> element("div[phx-click='select_section'][phx-value-id='#{section.id}']")
      |> render_click()

      lv |> element("div[phx-click='select_block'][phx-value-id='#{block.id}']") |> render_click()

      updated_text_json =
        Jason.encode!(%{
          "type" => "doc",
          "content" => [
            %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "Updated A"}]}
          ]
        })

      render_change(lv, "update_quiz_content", %{
        "block_id" => block.id,
        "correct_option_id" => "opt1",
        "options" => %{
          "0" => %{
            "id" => "opt1",
            "text" => updated_text_json,
            "is_correct" => "false",
            "explanation" => "New expl"
          }
        }
      })

      blocks = Content.list_blocks_by_section(section.id)
      updated_block = Enum.find(blocks, &(&1.id == block.id))

      opt = hd(updated_block.content["options"])

      assert opt["text"] == %{
               "type" => "doc",
               "content" => [
                 %{
                   "type" => "paragraph",
                   "content" => [%{"type" => "text", "text" => "Updated A"}]
                 }
               ]
             }

      assert opt["is_correct"] == true
      assert opt["explanation"] == "New expl"
    end

    test "add_quiz_pair adds an empty pair to a matching block", %{
      conn: conn,
      course: course,
      section: section,
      admin: admin
    } do
      {:ok, block} =
        Content.create_block(admin, %{
          "type" => "quiz_question",
          "section_id" => section.id,
          "content" => %{
            "question_type" => "matching",
            "body" => %{},
            "pairs" => [
              %{"id" => "p1", "left" => "A", "right" => "1"},
              %{"id" => "p2", "left" => "B", "right" => "2"}
            ]
          }
        })

      {:ok, lv, _html} = live(conn, ~p"/studio/courses/#{course.id}/builder")

      lv
      |> element("div[phx-click='select_section'][phx-value-id='#{section.id}']")
      |> render_click()

      lv |> element("div[phx-click='select_block'][phx-value-id='#{block.id}']") |> render_click()

      render_hook(lv, "add_quiz_pair", %{"id" => block.id})

      blocks = Content.list_blocks_by_section(section.id)
      updated_block = Enum.find(blocks, &(&1.id == block.id))
      pairs = updated_block.content["pairs"]

      assert length(pairs) == 3
      new_pair = List.last(pairs)
      assert is_binary(new_pair["id"])
      assert new_pair["left"] == %{"type" => "doc", "content" => [%{"type" => "paragraph"}]}
      assert new_pair["right"] == %{"type" => "doc", "content" => [%{"type" => "paragraph"}]}
    end

    test "remove_quiz_pair removes the pair by id", %{
      conn: conn,
      course: course,
      section: section,
      admin: admin
    } do
      {:ok, block} =
        Content.create_block(admin, %{
          "type" => "quiz_question",
          "section_id" => section.id,
          "content" => %{
            "question_type" => "matching",
            "body" => %{},
            "pairs" => [
              %{"id" => "p1", "left" => "A", "right" => "1"},
              %{"id" => "p2", "left" => "B", "right" => "2"},
              %{"id" => "p3", "left" => "C", "right" => "3"}
            ]
          }
        })

      {:ok, lv, _html} = live(conn, ~p"/studio/courses/#{course.id}/builder")

      lv
      |> element("div[phx-click='select_section'][phx-value-id='#{section.id}']")
      |> render_click()

      lv |> element("div[phx-click='select_block'][phx-value-id='#{block.id}']") |> render_click()

      render_hook(lv, "remove_quiz_pair", %{"id" => block.id, "pair_id" => "p1"})

      blocks = Content.list_blocks_by_section(section.id)
      updated_block = Enum.find(blocks, &(&1.id == block.id))
      pairs = updated_block.content["pairs"]

      assert length(pairs) == 2
      refute Enum.any?(pairs, &(&1["id"] == "p1"))
    end

    test "remove_quiz_pair rejects removal that would drop below the 2-pair minimum", %{
      conn: conn,
      course: course,
      section: section,
      admin: admin
    } do
      {:ok, block} =
        Content.create_block(admin, %{
          "type" => "quiz_question",
          "section_id" => section.id,
          "content" => %{
            "question_type" => "matching",
            "body" => %{},
            "pairs" => [
              %{"id" => "p1", "left" => "A", "right" => "1"},
              %{"id" => "p2", "left" => "B", "right" => "2"}
            ]
          }
        })

      {:ok, lv, _html} = live(conn, ~p"/studio/courses/#{course.id}/builder")

      lv
      |> element("div[phx-click='select_section'][phx-value-id='#{section.id}']")
      |> render_click()

      lv |> element("div[phx-click='select_block'][phx-value-id='#{block.id}']") |> render_click()

      render_hook(lv, "remove_quiz_pair", %{"id" => block.id, "pair_id" => "p1"})

      blocks = Content.list_blocks_by_section(section.id)
      updated_block = Enum.find(blocks, &(&1.id == block.id))

      assert length(updated_block.content["pairs"]) == 2
    end

    test "update_quiz_content merges decoded pairs into block content", %{
      conn: conn,
      course: course,
      section: section,
      admin: admin
    } do
      {:ok, block} =
        Content.create_block(admin, %{
          "type" => "quiz_question",
          "section_id" => section.id,
          "content" => %{
            "question_type" => "matching",
            "body" => %{},
            "pairs" => [
              %{"id" => "p1", "left" => "A", "right" => "1"},
              %{"id" => "p2", "left" => "B", "right" => "2"}
            ]
          }
        })

      {:ok, lv, _html} = live(conn, ~p"/studio/courses/#{course.id}/builder")

      lv
      |> element("div[phx-click='select_section'][phx-value-id='#{section.id}']")
      |> render_click()

      lv |> element("div[phx-click='select_block'][phx-value-id='#{block.id}']") |> render_click()

      render_change(lv, "update_quiz_content", %{
        "block_id" => block.id,
        "pairs" => %{
          "0" => %{"id" => "p1", "left" => "Updated left", "right" => "Updated right"},
          "1" => %{"id" => "p2", "left" => "B", "right" => "2"}
        }
      })

      blocks = Content.list_blocks_by_section(section.id)
      updated_block = Enum.find(blocks, &(&1.id == block.id))
      pair = hd(updated_block.content["pairs"])

      assert pair["id"] == "p1"

      assert pair["left"] == %{
               "type" => "doc",
               "content" => [
                 %{
                   "type" => "paragraph",
                   "content" => [%{"type" => "text", "text" => "Updated left"}]
                 }
               ]
             }
    end

    test "switching question_type to matching seeds two empty pairs", %{
      conn: conn,
      course: course,
      section: section,
      admin: admin
    } do
      {:ok, block} =
        Content.create_block(admin, %{
          "type" => "quiz_question",
          "section_id" => section.id,
          "content" => %{"question_type" => "open", "body" => %{}}
        })

      {:ok, lv, _html} = live(conn, ~p"/studio/courses/#{course.id}/builder")

      lv
      |> element("div[phx-click='select_section'][phx-value-id='#{section.id}']")
      |> render_click()

      lv |> element("div[phx-click='select_block'][phx-value-id='#{block.id}']") |> render_click()

      lv
      |> form("#block-inspector-form-#{block.id}", %{
        "block" => %{
          "id" => block.id,
          "content" => %{"question_type" => "matching"}
        }
      })
      |> render_change()

      blocks = Content.list_blocks_by_section(section.id)
      updated_block = Enum.find(blocks, &(&1.id == block.id))

      assert updated_block.content["question_type"] == "matching"
      assert length(updated_block.content["pairs"]) == 2
    end

    test "updates quiz block answer_type via inspector form", %{
      conn: conn,
      course: course,
      section: section,
      admin: admin
    } do
      {:ok, block} =
        Content.create_block(admin, %{
          "type" => "quiz_question",
          "section_id" => section.id,
          "content" => %{
            "question_type" => "open",
            "answer_type" => "plain_text",
            "body" => %{}
          }
        })

      {:ok, lv, _html} = live(conn, ~p"/studio/courses/#{course.id}/builder")

      lv
      |> element("div[phx-click='select_section'][phx-value-id='#{section.id}']")
      |> render_click()

      lv |> element("div[phx-click='select_block'][phx-value-id='#{block.id}']") |> render_click()

      lv
      |> form("#block-inspector-form-#{block.id}", %{
        "block" => %{
          "id" => block.id,
          "content" => %{
            "answer_type" => "rich_text"
          }
        }
      })
      |> render_change()

      blocks = Content.list_blocks_by_section(section.id)
      updated_block = Enum.find(blocks, &(&1.id == block.id))

      assert updated_block.content["answer_type"] == "rich_text"
    end

    test "updates quiz exam metadata and parses tags correctly", %{
      conn: conn,
      course: course,
      section: section,
      admin: admin
    } do
      {:ok, block} =
        Content.create_block(admin, %{
          "type" => "quiz_exam",
          "section_id" => section.id,
          "content" => %{
            "count" => 10,
            "mandatory_tags" => [],
            "include_tags" => [],
            "exclude_tags" => []
          }
        })

      {:ok, lv, _html} = live(conn, ~p"/studio/courses/#{course.id}/builder")

      lv
      |> element("div[phx-click='select_section'][phx-value-id='#{section.id}']")
      |> render_click()

      lv |> element("div[phx-click='select_block'][phx-value-id='#{block.id}']") |> render_click()

      lv
      |> form("#block-inspector-form-#{block.id}", %{
        "block" => %{
          "id" => block.id,
          "content" => %{
            "count" => "15",
            "time_limit" => "45"
          }
        },
        "tags_mandatory" => " elixir , phoenix, backend ",
        "tags_include" => "random, tricky",
        "tags_exclude" => "draft"
      })
      |> render_change()

      blocks = Content.list_blocks_by_section(section.id)
      updated_block = Enum.find(blocks, &(&1.id == block.id))

      assert updated_block.content["count"] == 15
      assert updated_block.content["time_limit"] == 45
      assert updated_block.content["mandatory_tags"] == ["elixir", "phoenix", "backend"]
      assert updated_block.content["include_tags"] == ["random", "tricky"]
      assert updated_block.content["exclude_tags"] == ["draft"]
    end

    test "adds a new quiz_exam block defaulting to the slot-based algorithm", %{
      conn: conn,
      course: course,
      section: section
    } do
      {:ok, lv, _html} = live(conn, ~p"/studio/courses/#{course.id}/builder")

      lv
      |> element("div[phx-click='select_section'][phx-value-id='#{section.id}']")
      |> render_click()

      lv |> element("button[phx-click='add_quiz_exam_block']") |> render_click()

      [block] = Content.list_blocks_by_section(section.id)
      assert block.type == :quiz_exam
      assert block.content["slots"] == []
    end

    test "adds and removes quiz exam slots and parses slot tags/count", %{
      conn: conn,
      course: course,
      section: section,
      admin: admin
    } do
      {:ok, block} =
        Content.create_block(admin, %{
          "type" => "quiz_exam",
          "section_id" => section.id,
          "content" => %{"slots" => []}
        })

      {:ok, lv, _html} = live(conn, ~p"/studio/courses/#{course.id}/builder")

      lv
      |> element("div[phx-click='select_section'][phx-value-id='#{section.id}']")
      |> render_click()

      lv |> element("div[phx-click='select_block'][phx-value-id='#{block.id}']") |> render_click()

      lv
      |> element("button[phx-click='add_quiz_slot'][phx-value-id='#{block.id}']")
      |> render_click()

      [updated_block] = Content.list_blocks_by_section(section.id)
      [slot] = updated_block.content["slots"]
      slot_id = slot["id"]

      lv
      |> form("#block-inspector-form-#{block.id}", %{
        "block" => %{
          "id" => block.id,
          "content" => %{
            "slots" => %{
              "0" => %{"id" => slot_id, "tags_string" => "elixir, hard", "count" => "3"}
            }
          }
        }
      })
      |> render_change()

      [updated_block] = Content.list_blocks_by_section(section.id)
      [slot] = updated_block.content["slots"]
      assert slot["tags"] == ["elixir", "hard"]
      assert slot["count"] == 3

      lv
      |> element(
        "button[phx-click='remove_quiz_slot'][phx-value-block_id='#{block.id}'][phx-value-slot_id='#{slot_id}']"
      )
      |> render_click()

      [updated_block] = Content.list_blocks_by_section(section.id)
      assert updated_block.content["slots"] == []
    end
  end

  describe "Modals & Navigation" do
    test "opens quick nav modal (Course Map)", %{conn: conn, course: course} do
      {:ok, lv, _html} = live(conn, ~p"/studio/courses/#{course.id}/builder")

      lv |> element("button[phx-click='open_quick_nav']") |> render_click()

      assert render(lv) =~ "Course Map"
      assert render(lv) =~ "View Root Level"
    end

    test "moves a section to a new parent via modal", %{
      conn: conn,
      course: course,
      admin: admin
    } do
      {:ok, parent} =
        Content.create_section(admin, %{
          "title" => "Target Folder",
          "course_id" => course.id,
          "owner_id" => admin.id
        })

      {:ok, child} =
        Content.create_section(admin, %{
          "title" => "Moving Folder",
          "course_id" => course.id,
          "owner_id" => admin.id
        })

      {:ok, lv, _html} = live(conn, ~p"/studio/courses/#{course.id}/builder")

      lv
      |> element("div[phx-click='select_section'][phx-value-id='#{child.id}']")
      |> render_click()

      lv |> element("button[phx-click='open_move_modal']") |> render_click()

      lv
      |> element("button[phx-click='move_section'][phx-value-target_id='#{parent.id}']")
      |> render_click()

      {:ok, updated_child} = Content.get_section(child.id)
      assert updated_child.parent_id == parent.id
    end
  end

  describe "Media Upload State" do
    setup %{course: course, admin: admin} do
      {:ok, section} =
        Content.create_section(admin, %{
          "title" => "Uploads Lesson",
          "course_id" => course.id
        })

      {:ok, block} =
        Content.create_block(admin, %{
          "type" => "image",
          "section_id" => section.id,
          "content" => %{"url" => nil, "alt" => ""}
        })

      %{section: section, block: block}
    end

    test "opens media upload modal when requested", %{
      conn: conn,
      course: course,
      section: section,
      block: block
    } do
      {:ok, lv, _html} = live(conn, ~p"/studio/courses/#{course.id}/builder")

      lv
      |> element("div[phx-click='select_section'][phx-value-id='#{section.id}']")
      |> render_click()

      lv
      |> element("div[phx-click='select_block'][phx-value-id='#{block.id}']")
      |> render_click()

      lv
      |> element("button[phx-click='request_media_upload']", "Upload File")
      |> render_click()

      html = render(lv)
      assert html =~ "Upload Media"
      assert html =~ "Click or drag files here"
    end

    test "cancels media upload and closes modal", %{
      conn: conn,
      course: course,
      section: section,
      block: block
    } do
      {:ok, lv, _html} = live(conn, ~p"/studio/courses/#{course.id}/builder")

      lv
      |> element("div[phx-click='select_section'][phx-value-id='#{section.id}']")
      |> render_click()

      render_hook(lv, "request_media_upload", %{"block_id" => block.id, "media_type" => "image"})

      assert render(lv) =~ "Upload Media"

      lv
      |> element("button[phx-click='cancel_media_upload']")
      |> render_click()

      refute render(lv) =~ "Upload Media"
    end
  end

  describe "Clipboard Media Upload" do
    setup %{course: course, admin: admin} do
      {:ok, section} =
        Content.create_section(admin, %{
          "title" => "Clipboard Lesson",
          "course_id" => course.id
        })

      %{section: section}
    end

    test "handles clipboard upload request and generates presigned url", %{
      conn: conn,
      course: course,
      section: section
    } do
      {:ok, lv, _html} = live(conn, ~p"/studio/courses/#{course.id}/builder")

      lv
      |> element("div[phx-click='select_section'][phx-value-id='#{section.id}']")
      |> render_click()

      render_hook(lv, "media_upload_clipboard_request", %{
        "block_id" => Ecto.UUID.generate(),
        "file_name" => "clipboard_1234.png",
        "file_type" => "image/png",
        "file_size" => 1024,
        "temp_id" => "temp_uuid_123"
      })

      assert_push_event(lv, "media_upload_presigned", %{
        temp_id: "temp_uuid_123",
        upload_url: upload_url,
        final_url: final_url
      })

      assert upload_url =~ "X-Amz-Signature"
      assert final_url =~ "/media/courses/#{course.id}/"
    end

    test "handles successful clipboard upload and inserts media", %{
      conn: conn,
      course: course,
      section: section
    } do
      block_id = Ecto.UUID.generate()

      {:ok, lv, _html} = live(conn, ~p"/studio/courses/#{course.id}/builder")

      lv
      |> element("div[phx-click='select_section'][phx-value-id='#{section.id}']")
      |> render_click()

      render_hook(lv, "media_upload_clipboard_request", %{
        "block_id" => block_id,
        "file_name" => "test.png",
        "file_type" => "image/png",
        "file_size" => 2048,
        "temp_id" => "success_temp_id"
      })

      assert_push_event(lv, "media_upload_presigned", %{final_url: final_url})

      render_hook(lv, "media_upload_clipboard_success", %{
        "block_id" => block_id,
        "temp_id" => "success_temp_id",
        "final_url" => final_url
      })

      {:ok, {files, _meta}} = Athena.Media.list_files()
      assert length(files) == 1
      uploaded_file = hd(files)

      assert uploaded_file.original_name == "test.png"
      assert uploaded_file.size == 2048
      assert uploaded_file.mime_type == "image/png"
      assert uploaded_file.context == :course_material

      assert_push_event(lv, "insert_media", %{
        block_id: ^block_id,
        type: "tiptap_image",
        url: ^final_url
      })
    end

    test "reader role cannot trigger clipboard uploads", %{
      conn: conn,
      course: course,
      section: section
    } do
      role = insert(:role, permissions: ["courses.read", "courses.update"])
      reader = insert(:account, role: role)
      insert(:course_share, course: course, account_id: reader.id, role: :reader)

      reader_conn = init_test_session(conn, %{"account_id" => reader.id})

      {:ok, lv, _html} = live(reader_conn, ~p"/studio/courses/#{course.id}/builder")

      lv
      |> element("div[phx-click='select_section'][phx-value-id='#{section.id}']")
      |> render_click()

      render_hook(lv, "media_upload_clipboard_request", %{
        "block_id" => Ecto.UUID.generate(),
        "file_name" => "hack.png",
        "file_type" => "image/png",
        "file_size" => 1024,
        "temp_id" => "hack_temp_id"
      })

      refute_push_event(lv, "media_upload_presigned", %{})
    end
  end

  describe "Library Integration" do
    setup %{course: course, admin: admin} do
      {:ok, section} =
        Content.create_section(admin, %{
          "title" => "Library Lesson",
          "course_id" => course.id
        })

      %{section: section}
    end

    test "saves an existing block to the library", %{
      conn: conn,
      course: course,
      section: section,
      admin: admin
    } do
      {:ok, block} =
        Content.create_block(admin, %{
          "type" => "text",
          "section_id" => section.id,
          "content" => %{"text" => "Important content"}
        })

      {:ok, lv, _html} = live(conn, ~p"/studio/courses/#{course.id}/builder")

      lv
      |> element("div[phx-click='select_section'][phx-value-id='#{section.id}']")
      |> render_click()

      lv
      |> element("div[phx-click='select_block'][phx-value-id='#{block.id}']")
      |> render_click()

      lv |> element("button[phx-click='open_save_library_modal']") |> render_click()

      assert render(lv) =~ "Save to Library"

      lv
      |> form("#save-library-modal form", %{
        "title" => "My Reusable Text",
        "tags_string" => "cool, text"
      })
      |> render_submit()

      assert render(lv) =~ "Saved to library!"

      {:ok, {lib_blocks, _}} = Content.list_library_blocks(admin, %{})
      assert length(lib_blocks) == 1
      assert hd(lib_blocks).title == "My Reusable Text"
      assert hd(lib_blocks).tags == ["cool", "text"]
    end

    test "inserts a block from the library into the active section", %{
      conn: conn,
      course: course,
      section: section,
      admin: admin
    } do
      lib_block =
        insert(:library_block,
          title: "Global Quiz",
          type: :quiz_question,
          content: %{
            "question_type" => "exact_match",
            "body" => %{"type" => "doc", "content" => [%{"type" => "paragraph"}]},
            "correct_answer" => "flag{test}"
          },
          owner_id: admin.id
        )

      insert(:course_library_block, course: course, library_block: lib_block)

      {:ok, lv, _html} = live(conn, ~p"/studio/courses/#{course.id}/builder")

      lv
      |> element("div[phx-click='select_section'][phx-value-id='#{section.id}']")
      |> render_click()

      lv |> element("button[phx-click='open_library_picker']") |> render_click()

      assert render(lv) =~ "Global Quiz"

      lv
      |> element("button[phx-click='insert_from_library'][phx-value-id='#{lib_block.id}']")
      |> render_click()

      assert render(lv) =~ "Block inserted from library!"

      blocks = Content.list_blocks_by_section(section.id)
      assert length(blocks) == 1
      assert hd(blocks).type == :quiz_question
    end

    test "searches library templates in the slide-over picker", %{
      conn: conn,
      course: course,
      section: section,
      admin: admin
    } do
      alpha = insert(:library_block, title: "Alpha Template", owner_id: admin.id)
      beta = insert(:library_block, title: "Beta Template", owner_id: admin.id)

      insert(:course_library_block, course: course, library_block: alpha)
      insert(:course_library_block, course: course, library_block: beta)

      {:ok, lv, _html} = live(conn, ~p"/studio/courses/#{course.id}/builder")

      lv
      |> element("div[phx-click='select_section'][phx-value-id='#{section.id}']")
      |> render_click()

      lv |> element("button[phx-click='open_library_picker']") |> render_click()

      html =
        lv
        |> form("#library-search-form", %{"search" => "Alpha"})
        |> render_change()

      assert html =~ "Alpha Template"
      refute html =~ "Beta Template"
    end
  end

  describe "Test Run - code execution inside the nested player" do
    test "clicking Run on a SQL block inside a live Test Run actually executes it", %{
      conn: conn,
      course: course,
      admin: admin
    } do
      {:ok, section} =
        Content.create_section(admin, %{"title" => "SQL Lesson", "course_id" => course.id})

      {:ok, block} =
        Content.create_block(admin, %{
          "type" => "code",
          "section_id" => section.id,
          "content" => %{
            "language" => "sql",
            "time_limit" => 2.0,
            "evaluation_mode" => "query_result",
            "setup_sql" =>
              "CREATE TABLE users (id INT, name TEXT); INSERT INTO users VALUES (1, 'Alice');",
            "solution_code" => "SELECT * FROM users ORDER BY id;"
          }
        })

      {:ok, lv, _html} = live(conn, ~p"/studio/courses/#{course.id}/builder")

      lv
      |> element("div[phx-click='select_section'][phx-value-id='#{section.id}']")
      |> render_click()

      lv
      |> element("button[phx-click='start_test_run']")
      |> render_click()

      assert render(lv) =~ "Test run"

      session = Repo.one!(Athena.Learning.TestRunSession)
      player = find_live_child(lv, "test-run-player-#{session.id}")
      assert player

      player
      |> form("#code-form-#{block.id}")
      |> render_change(%{
        "block_id" => block.id,
        "answer" => %{"code" => "SELECT * FROM users ORDER BY id;"}
      })

      player
      |> element("button[phx-click='run_code'][phx-value-block_id='#{block.id}']")
      |> render_click()

      assert [job] = Oban.Testing.all_enqueued(worker: Athena.Execution.TestWorker, repo: Repo)
      assert :ok = Oban.Testing.perform_job(Athena.Execution.TestWorker, job.args, repo: Repo)

      assert render(player) =~ "ACCEPTED"
    end

    test "a Test Run never writes engagement_events rows for its ephemeral account", %{
      conn: conn,
      course: course,
      admin: admin
    } do
      # `Athena.Learning.TestRuns.cleanup/1` purges submissions, progress,
      # and gamification rows for the ephemeral test-run account, but does
      # not (and structurally cannot cheaply) purge `engagement_events` -
      # so the Player must simply never write them while `@test_run` is set,
      # instead of leaving orphaned telemetry behind after every preview.
      {:ok, section} =
        Content.create_section(admin, %{"title" => "SQL Lesson", "course_id" => course.id})

      {:ok, block} =
        Content.create_block(admin, %{
          "type" => "code",
          "section_id" => section.id,
          "content" => %{
            "language" => "sql",
            "time_limit" => 2.0,
            "evaluation_mode" => "query_result",
            "setup_sql" =>
              "CREATE TABLE users (id INT, name TEXT); INSERT INTO users VALUES (1, 'Alice');",
            "solution_code" => "SELECT * FROM users ORDER BY id;"
          }
        })

      {:ok, lv, _html} = live(conn, ~p"/studio/courses/#{course.id}/builder")

      lv
      |> element("div[phx-click='select_section'][phx-value-id='#{section.id}']")
      |> render_click()

      lv
      |> element("button[phx-click='start_test_run']")
      |> render_click()

      session = Repo.one!(Athena.Learning.TestRunSession)
      player = find_live_child(lv, "test-run-player-#{session.id}")
      assert player

      player
      |> form("#code-form-#{block.id}")
      |> render_change(%{
        "block_id" => block.id,
        "answer" => %{"code" => "SELECT * FROM users ORDER BY id;"}
      })

      player
      |> element("button[phx-click='run_code'][phx-value-block_id='#{block.id}']")
      |> render_click()

      assert [job] = Oban.Testing.all_enqueued(worker: Athena.Execution.TestWorker, repo: Repo)
      assert :ok = Oban.Testing.perform_job(Athena.Execution.TestWorker, job.args, repo: Repo)

      refute has_element?(player, "[phx-hook='EngagementTracker']")
      assert Repo.aggregate(Athena.Engagement.Event, :count, :id) == 0
    end

    test "clicking Run inside a Test Run works immediately, without editing the pre-filled code first",
         %{conn: conn, course: course, admin: admin} do
      # This is the exact bug report: an instructor opens Test Run, the code
      # editor already shows the block's `initial_code`, and clicking Run
      # right away silently did nothing - `do_run_code/4` only looked at
      # `socket.assigns.drafts`, which stays empty until the student (or
      # instructor) actually edits the code. Worse, on a nested Test Run
      # player there's no flash outlet, so the "Please write some code
      # first!" error wasn't even visible - it just looked broken.
      {:ok, section} =
        Content.create_section(admin, %{"title" => "SQL Lesson", "course_id" => course.id})

      {:ok, block} =
        Content.create_block(admin, %{
          "type" => "code",
          "section_id" => section.id,
          "content" => %{
            "language" => "sql",
            "time_limit" => 2.0,
            "evaluation_mode" => "query_result",
            "initial_code" => "SELECT * FROM users ORDER BY id;",
            "setup_sql" =>
              "CREATE TABLE users (id INT, name TEXT); INSERT INTO users VALUES (1, 'Alice');",
            "solution_code" => "SELECT * FROM users ORDER BY id;"
          }
        })

      {:ok, lv, _html} = live(conn, ~p"/studio/courses/#{course.id}/builder")

      lv
      |> element("div[phx-click='select_section'][phx-value-id='#{section.id}']")
      |> render_click()

      lv
      |> element("button[phx-click='start_test_run']")
      |> render_click()

      session = Repo.one!(Athena.Learning.TestRunSession)
      player = find_live_child(lv, "test-run-player-#{session.id}")
      assert player

      # No form/render_change here - Run is clicked with zero prior edits.
      player
      |> element("button[phx-click='run_code'][phx-value-block_id='#{block.id}']")
      |> render_click()

      assert [job] = Oban.Testing.all_enqueued(worker: Athena.Execution.TestWorker, repo: Repo)
      assert :ok = Oban.Testing.perform_job(Athena.Execution.TestWorker, job.args, repo: Repo)

      assert render(player) =~ "ACCEPTED"
    end
  end

  describe "Builder ACL & Security" do
    test "kicks out a user who does not own the course", %{conn: conn} do
      sneaky_role =
        insert(:role,
          permissions: ["courses.read", "courses.update"],
          policies: %{"courses.read" => ["own_only"], "courses.update" => ["own_only"]}
        )

      sneaky_user = insert(:account, role: sneaky_role)
      target_course = insert(:course)

      sneaky_conn = init_test_session(conn, %{"account_id" => sneaky_user.id})

      assert {:error, {:live_redirect, %{to: "/studio/courses"}}} =
               live(sneaky_conn, ~p"/studio/courses/#{target_course.id}/builder")
    end

    test "kicks out a student completely via Permission Hook", %{conn: conn, course: course} do
      student = insert(:account, role: insert(:role, permissions: []))
      student_conn = init_test_session(conn, %{"account_id" => student.id})

      assert {:error, {:redirect, %{to: "/dashboard"}}} =
               live(student_conn, ~p"/studio/courses/#{course.id}/builder")
    end

    test "allows global admin to access and edit a course they don't own", %{conn: conn} do
      other_user = insert(:account)
      other_course = insert(:course, owner_id: other_user.id)

      {:ok, _lv, html} = live(conn, ~p"/studio/courses/#{other_course.id}/builder")

      assert html =~ "Inspector"
      assert html =~ "Add Section"
    end
  end

  describe "Collaborator Roles (Reader vs Writer)" do
    setup %{admin: owner, course: course} do
      role = insert(:role, permissions: ["courses.read", "courses.update"])
      collaborator = insert(:account, role: role)

      {:ok, section} =
        Content.create_section(owner, %{"title" => "Collab Lesson", "course_id" => course.id})

      %{section: section, collaborator: collaborator}
    end

    test "reader sees read-only mode and no add buttons", %{
      conn: conn,
      course: course,
      collaborator: reader
    } do
      insert(:course_share, course: course, account_id: reader.id, role: :reader)
      reader_conn = init_test_session(conn, %{"account_id" => reader.id})

      {:ok, _lv, html} = live(reader_conn, ~p"/studio/courses/#{course.id}/builder")

      refute html =~ "Add Section"
    end

    test "writer sees edit mode and inspector", %{
      conn: conn,
      course: course,
      collaborator: writer
    } do
      insert(:course_share, course: course, account_id: writer.id, role: :writer)
      writer_conn = init_test_session(conn, %{"account_id" => writer.id})

      {:ok, _lv, html} = live(writer_conn, ~p"/studio/courses/#{course.id}/builder")

      assert html =~ "Inspector"
      assert html =~ "Add Section"
    end

    test "reader is blocked from mutating events at the handler level", %{
      conn: conn,
      course: course,
      section: section,
      collaborator: reader
    } do
      insert(:course_share, course: course, account_id: reader.id, role: :reader)
      reader_conn = init_test_session(conn, %{"account_id" => reader.id})

      {:ok, lv, _html} = live(reader_conn, ~p"/studio/courses/#{course.id}/builder")

      lv
      |> element("div[phx-click='select_section'][phx-value-id='#{section.id}']")
      |> render_click()

      render_hook(lv, "add_text_block", %{"after_id" => nil})

      blocks = Content.list_blocks_by_section(section.id)
      assert blocks == []
    end
  end

  describe "URL-driven Navigation & Scroll" do
    setup %{course: course, admin: admin} do
      {:ok, section} =
        Content.create_section(admin, %{
          "title" => "Scroll Target Section",
          "course_id" => course.id
        })

      {:ok, block1} =
        Content.create_block(admin, %{
          "type" => "text",
          "section_id" => section.id,
          "content" => %{}
        })

      {:ok, block2} =
        Content.create_block(admin, %{
          "type" => "code",
          "section_id" => section.id,
          "content" => %{}
        })

      %{section: section, block1: block1, block2: block2}
    end

    test "opening URL with block_id pushes scroll_to_block event",
         %{conn: conn, course: course, section: section, block2: block2} do
      block_id = block2.id

      {:ok, lv, _html} =
        live(
          conn,
          ~p"/studio/courses/#{course.id}/builder/sections/#{section.id}/blocks/#{block_id}"
        )

      assert_push_event(lv, "scroll_to_block", %{id: ^block_id})
      assert has_element?(lv, "#block-wrapper-#{block_id}")
    end

    test "opening URL with only section_id loads section correctly",
         %{conn: conn, course: course, section: section} do
      {:ok, lv, _html} =
        live(conn, ~p"/studio/courses/#{course.id}/builder/sections/#{section.id}")

      assert has_element?(lv, "#canvas-blocks-list")
    end

    test "clicking a block triggers scroll_to_block via push_patch",
         %{conn: conn, course: course, section: section, block1: block1} do
      block_id = block1.id

      {:ok, lv, _html} =
        live(conn, ~p"/studio/courses/#{course.id}/builder/sections/#{section.id}")

      lv
      |> element("div[phx-click='select_block'][phx-value-id='#{block_id}']")
      |> render_click()

      assert_push_event(lv, "scroll_to_block", %{id: ^block_id})
    end

    test "navigating between blocks via UI pushes scroll for each selection",
         %{conn: conn, course: course, section: section, block1: block1, block2: block2} do
      id1 = block1.id
      id2 = block2.id

      {:ok, lv, _html} =
        live(conn, ~p"/studio/courses/#{course.id}/builder/sections/#{section.id}")

      lv
      |> element("div[phx-click='select_block'][phx-value-id='#{id1}']")
      |> render_click()

      assert_push_event(lv, "scroll_to_block", %{id: ^id1})

      lv
      |> element("div[phx-click='select_block'][phx-value-id='#{id2}']")
      |> render_click()

      assert_push_event(lv, "scroll_to_block", %{id: ^id2})
    end

    test "deselecting block clears selection without pushing scroll",
         %{conn: conn, course: course, section: section, block1: block1} do
      block_id = block1.id

      {:ok, lv, _html} =
        live(
          conn,
          ~p"/studio/courses/#{course.id}/builder/sections/#{section.id}/blocks/#{block_id}"
        )

      assert_push_event(lv, "scroll_to_block", %{id: ^block_id})

      render_hook(lv, "deselect_block")

      refute has_element?(lv, "#block-wrapper-#{block_id}.ring-2")
    end
  end

  describe "Section Creation Navigation" do
    test "adding a section changes URL to new section path", %{conn: conn, course: course} do
      {:ok, lv, _html} = live(conn, ~p"/studio/courses/#{course.id}/builder")

      assert render(lv) =~ "No sections yet"

      lv |> element("button[phx-click='add_section']") |> render_click()

      html = render(lv)
      assert html =~ "New Lesson"
      assert html =~ "Section Title"
      assert html =~ ~s(phx-change="update_section_meta")
    end
  end

  describe "Section Deletion Navigation" do
    setup %{course: course, admin: admin} do
      {:ok, parent} =
        Content.create_section(admin, %{
          "title" => "Parent Section",
          "course_id" => course.id
        })

      {:ok, child} =
        Content.create_section(admin, %{
          "title" => "Child Section",
          "course_id" => course.id,
          "parent_id" => parent.id
        })

      %{course: course, parent: parent, child: child}
    end

    test "deleting a child section navigates to its parent", %{
      conn: conn,
      course: course,
      parent: parent,
      child: child
    } do
      {:ok, lv, _html} = live(conn, ~p"/studio/courses/#{course.id}/builder/sections/#{child.id}")

      lv |> element("button[phx-click='delete_section_click']") |> render_click()
      lv |> element("#delete-section-modal button", "Delete") |> render_click()

      html = render(lv)
      refute html =~ child.title
      assert html =~ parent.title
    end
  end

  describe "Save to Library - preserves every content field, per block type" do
    setup %{course: course, admin: admin} do
      {:ok, section} =
        Content.create_section(admin, %{
          "title" => "Library Fidelity Lesson",
          "course_id" => course.id
        })

      %{section: section}
    end

    test "text block: the whole tiptap doc round-trips untouched", %{
      conn: conn,
      course: course,
      section: section
    } do
      content = %{
        "type" => "doc",
        "content" => [
          %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "Hello world"}]}
        ]
      }

      block = insert(:block, type: :text, section: section, content: content)
      lib = save_block_to_library(conn, course, section, block, "Text Template")

      assert lib.content == content
    end

    test "image block: url and alt survive", %{conn: conn, course: course, section: section} do
      content = %{"url" => "https://cdn.example.com/img.png", "alt" => "A cat"}
      block = insert(:block, type: :image, section: section, content: content)
      lib = save_block_to_library(conn, course, section, block, "Image Template")

      assert lib.content["url"] == "https://cdn.example.com/img.png"
      assert lib.content["alt"] == "A cat"
    end

    test "video block: url, poster_url and controls survive", %{
      conn: conn,
      course: course,
      section: section
    } do
      content = %{
        "url" => "https://cdn.example.com/vid.mp4",
        "poster_url" => "https://cdn.example.com/poster.png",
        "controls" => true
      }

      block = insert(:block, type: :video, section: section, content: content)
      lib = save_block_to_library(conn, course, section, block, "Video Template")

      assert lib.content["url"] == "https://cdn.example.com/vid.mp4"
      assert lib.content["poster_url"] == "https://cdn.example.com/poster.png"
      assert lib.content["controls"] == true
    end

    test "attachment block: description doc and files survive", %{
      conn: conn,
      course: course,
      section: section
    } do
      content = %{
        "description" => %{
          "type" => "doc",
          "content" => [
            %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "Read this"}]}
          ]
        },
        "files" => [%{"url" => "https://cdn.example.com/f.pdf", "name" => "f.pdf"}]
      }

      block = insert(:block, type: :attachment, section: section, content: content)
      lib = save_block_to_library(conn, course, section, block, "Attachment Template")

      assert lib.content["description"] == content["description"]
      assert lib.content["files"] == content["files"]
    end

    test "file_assignment block: max_files and instructions body survive", %{
      conn: conn,
      course: course,
      section: section
    } do
      content = %{
        "max_files" => 3,
        "body" => %{"type" => "doc", "content" => [%{"type" => "paragraph"}]}
      }

      block = insert(:block, type: :file_assignment, section: section, content: content)
      lib = save_block_to_library(conn, course, section, block, "File Assignment Template")

      assert lib.content["max_files"] == 3
      assert lib.content["body"] == content["body"]
    end

    test "quiz_question block: options, pairs and every scalar field survive", %{
      conn: conn,
      course: course,
      section: section
    } do
      content = %{
        "question_type" => "matching",
        "answer_type" => "plain_text",
        "body" => %{"type" => "doc", "content" => [%{"type" => "paragraph"}]},
        "correct_answer" => "flag{ignored-for-matching}",
        "case_sensitive" => true,
        "max_attempts" => 3,
        "general_explanation" => "Because reasons",
        "options" => [
          %{
            "id" => Ecto.UUID.generate(),
            "text" => %{"type" => "doc", "content" => []},
            "is_correct" => true,
            "explanation" => "yes"
          },
          %{
            "id" => Ecto.UUID.generate(),
            "text" => %{"type" => "doc", "content" => []},
            "is_correct" => false,
            "explanation" => "no"
          }
        ],
        "pairs" => [
          %{
            "id" => Ecto.UUID.generate(),
            "left" => %{"type" => "doc", "content" => []},
            "right" => %{"type" => "doc", "content" => []}
          },
          %{
            "id" => Ecto.UUID.generate(),
            "left" => %{"type" => "doc", "content" => []},
            "right" => %{"type" => "doc", "content" => []}
          }
        ]
      }

      block = insert(:block, type: :quiz_question, section: section, content: content)
      lib = save_block_to_library(conn, course, section, block, "Quiz Question Template")

      assert lib.content["question_type"] == "matching"
      assert lib.content["answer_type"] == "plain_text"
      assert lib.content["body"] == content["body"]
      assert lib.content["correct_answer"] == "flag{ignored-for-matching}"
      assert lib.content["case_sensitive"] == true
      assert lib.content["max_attempts"] == 3
      assert lib.content["general_explanation"] == "Because reasons"
      assert length(lib.content["options"]) == 2
      assert Enum.map(lib.content["options"], & &1["is_correct"]) == [true, false]
      assert Enum.map(lib.content["options"], & &1["explanation"]) == ["yes", "no"]
      assert length(lib.content["pairs"]) == 2
    end

    test "quiz_exam block: slots and every tag/limit field survive", %{
      conn: conn,
      course: course,
      section: section
    } do
      content = %{
        "count" => 5,
        "time_limit" => 600,
        "allowed_blur_attempts" => 2,
        "mandatory_tags" => ["core"],
        "include_tags" => ["bonus"],
        "exclude_tags" => ["deprecated"],
        "slots" => [%{"id" => "slot-1", "count" => 2, "tags" => ["arrays"]}]
      }

      block = insert(:block, type: :quiz_exam, section: section, content: content)
      lib = save_block_to_library(conn, course, section, block, "Quiz Exam Template")

      assert lib.content["count"] == 5
      assert lib.content["time_limit"] == 600
      assert lib.content["allowed_blur_attempts"] == 2
      assert lib.content["mandatory_tags"] == ["core"]
      assert lib.content["include_tags"] == ["bonus"]
      assert lib.content["exclude_tags"] == ["deprecated"]
      assert [%{"id" => "slot-1", "count" => 2, "tags" => ["arrays"]}] = lib.content["slots"]
    end

    test "ticket_exam block: slots and limit fields survive", %{
      conn: conn,
      course: course,
      section: section
    } do
      content = %{
        "time_limit" => 1200,
        "allowed_blur_attempts" => 1,
        "slots" => [%{"id" => "slot-1", "tags" => ["sql"]}]
      }

      block = insert(:block, type: :ticket_exam, section: section, content: content)
      lib = save_block_to_library(conn, course, section, block, "Ticket Exam Template")

      assert lib.content["time_limit"] == 1200
      assert lib.content["allowed_blur_attempts"] == 1
      assert [%{"id" => "slot-1", "tags" => ["sql"]}] = lib.content["slots"]
    end

    test "code block (non-sql): initial/solution code, test cases and limits survive", %{
      conn: conn,
      course: course,
      section: section
    } do
      content = %{
        "language" => "python3",
        "time_limit" => 3.5,
        "memory_limit" => 131_072,
        "max_attempts" => 5,
        "initial_code" => "def solve():\n    pass",
        "solution_code" => "def solve():\n    return 42",
        "body" => %{"type" => "doc", "content" => [%{"type" => "paragraph"}]},
        "test_cases" => [
          %{"input" => "1", "expected_output" => "2", "is_hidden" => false, "weight" => 50},
          %{"input" => "2", "expected_output" => "3", "is_hidden" => true, "weight" => 50}
        ]
      }

      block = insert(:block, type: :code, section: section, content: content)
      lib = save_block_to_library(conn, course, section, block, "Code Template")

      assert lib.content["language"] == "python3"
      assert lib.content["time_limit"] == 3.5
      assert lib.content["memory_limit"] == 131_072
      assert lib.content["max_attempts"] == 5
      assert lib.content["initial_code"] == "def solve():\n    pass"
      assert lib.content["solution_code"] == "def solve():\n    return 42"
      assert lib.content["body"] == content["body"]
      assert length(lib.content["test_cases"]) == 2
      assert Enum.map(lib.content["test_cases"], & &1["weight"]) == [50, 50]
    end

    test "code block (sql): setup/check SQL and evaluation mode survive a description edit and the library copy",
         %{conn: conn, course: course, section: section, admin: admin} do
      content = %{
        "language" => "sql",
        "time_limit" => 2.5,
        "max_attempts" => 2,
        "solution_code" => "SELECT * FROM users ORDER BY id;",
        "setup_sql" => "CREATE TABLE users (id INT, name TEXT);",
        "check_sql" => "SELECT 'OK';",
        "evaluation_mode" => "state_verification",
        "body" => %{
          "type" => "doc",
          "content" => [
            %{
              "type" => "paragraph",
              "content" => [%{"type" => "text", "text" => "Original instructions"}]
            }
          ]
        }
      }

      {:ok, block} =
        Content.create_block(admin, %{
          "type" => "code",
          "section_id" => section.id,
          "content" => content
        })

      {:ok, lv, _html} = live(conn, ~p"/studio/courses/#{course.id}/builder")

      lv
      |> element("div[phx-click='select_section'][phx-value-id='#{section.id}']")
      |> render_click()

      lv
      |> element("div[phx-click='select_block'][phx-value-id='#{block.id}']")
      |> render_click()

      # Regression guard: editing the block's rich-text instructions used to
      # wipe the SQL sandbox config, because both were stored under the same
      # `content["body"]` key (see Athena.Content.CodeChallenge).
      new_instructions = %{
        "type" => "doc",
        "content" => [
          %{
            "type" => "paragraph",
            "content" => [%{"type" => "text", "text" => "Edited instructions"}]
          }
        ]
      }

      render_hook(lv, "update_content", %{"id" => block.id, "content" => new_instructions})

      {:ok, edited_block} = Content.get_block(block.id)
      assert edited_block.content["body"] == new_instructions
      assert edited_block.content["setup_sql"] == "CREATE TABLE users (id INT, name TEXT);"
      assert edited_block.content["check_sql"] == "SELECT 'OK';"
      assert edited_block.content["solution_code"] == "SELECT * FROM users ORDER BY id;"
      assert edited_block.content["evaluation_mode"] == "state_verification"

      lv |> element("button[phx-click='open_save_library_modal']") |> render_click()

      lv
      |> form("#save-library-modal form", %{"title" => "SQL Code Template", "tags_string" => ""})
      |> render_submit()

      lib = Repo.get_by!(LibraryBlock, title: "SQL Code Template")

      assert lib.content["language"] == "sql"
      assert lib.content["setup_sql"] == "CREATE TABLE users (id INT, name TEXT);"
      assert lib.content["check_sql"] == "SELECT 'OK';"
      assert lib.content["solution_code"] == "SELECT * FROM users ORDER BY id;"
      assert lib.content["evaluation_mode"] == "state_verification"
      assert lib.content["body"] == new_instructions
    end

    test "saving a block to the library also pins it to the course's own library", %{
      conn: conn,
      course: course,
      section: section
    } do
      block = insert(:block, type: :text, section: section, content: %{"text" => "Pin me"})
      lib = save_block_to_library(conn, course, section, block, "Auto-Pinned Template")

      assert Repo.get_by(CourseLibraryBlock, course_id: course.id, library_block_id: lib.id)
    end
  end

  defp save_block_to_library(conn, course, section, block, title) do
    {:ok, lv, _html} = live(conn, ~p"/studio/courses/#{course.id}/builder")

    lv
    |> element("div[phx-click='select_section'][phx-value-id='#{section.id}']")
    |> render_click()

    lv
    |> element("div[phx-click='select_block'][phx-value-id='#{block.id}']")
    |> render_click()

    lv |> element("button[phx-click='open_save_library_modal']") |> render_click()

    lv
    |> form("#save-library-modal form", %{"title" => title, "tags_string" => ""})
    |> render_submit()

    Repo.get_by!(LibraryBlock, title: title)
  end
end
