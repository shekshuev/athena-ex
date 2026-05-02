defmodule AthenaWeb.StudioLive.BuilderTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory
  alias Athena.Content

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

    test "renders builder successfully with course title", %{conn: conn, course: course} do
      {:ok, _lv, html} = live(conn, ~p"/studio/courses/#{course.id}/builder")

      assert html =~ course.title
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
              %{"id" => "opt1", "text" => "A", "is_correct" => false, "explanation" => ""}
            ]
          }
        })

      {:ok, lv, _html} = live(conn, ~p"/studio/courses/#{course.id}/builder")

      lv
      |> element("div[phx-click='select_section'][phx-value-id='#{section.id}']")
      |> render_click()

      lv |> element("div[phx-click='select_block'][phx-value-id='#{block.id}']") |> render_click()

      lv
      |> form("#quiz-form-#{block.id}", %{
        "correct_option_id" => "opt1",
        "options" => %{
          "0" => %{
            "id" => "opt1",
            "text" => "Updated A",
            "is_correct" => "false",
            "explanation" => "New expl"
          }
        }
      })
      |> render_change()

      blocks = Content.list_blocks_by_section(section.id)
      updated_block = Enum.find(blocks, &(&1.id == block.id))

      opt = hd(updated_block.content["options"])

      assert opt["text"] == "Updated A"
      assert opt["is_correct"] == true
      assert opt["explanation"] == "New expl"
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
      insert(:library_block, title: "Alpha Template", owner_id: admin.id)
      insert(:library_block, title: "Beta Template", owner_id: admin.id)

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

  describe "Builder ACL & Security" do
    test "kicks out a user who does not own the course", %{conn: conn} do
      sneaky_role =
        insert(:role,
          permissions: ["courses.update"],
          policies: %{"courses.update" => ["own_only"]}
        )

      sneaky_user = insert(:account, role: sneaky_role)

      target_course = insert(:course)

      sneaky_conn = init_test_session(conn, %{"account_id" => sneaky_user.id})

      assert {:error, {:live_redirect, %{to: "/studio/courses"}}} =
               live(sneaky_conn, ~p"/studio/courses/#{target_course.id}/builder")
    end

    test "kicks out a student completely", %{conn: conn, course: course} do
      student = insert(:account, role: insert(:role, permissions: []))
      student_conn = init_test_session(conn, %{"account_id" => student.id})

      assert {:error, {:redirect, %{to: "/dashboard"}}} =
               live(student_conn, ~p"/studio/courses/#{course.id}/builder")
    end
  end
end
