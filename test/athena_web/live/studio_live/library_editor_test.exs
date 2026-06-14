defmodule AthenaWeb.StudioLive.LibraryEditorTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory
  alias Athena.Content

  setup %{conn: conn} do
    role =
      insert(:role,
        permissions: ["library.read", "library.update", "library.delete"],
        policies: %{
          "library.read" => ["own_only"],
          "library.update" => ["own_only"],
          "library.delete" => ["own_only"]
        }
      )

    admin = insert(:account, role: role)
    conn = init_test_session(conn, %{"account_id" => admin.id})

    %{conn: conn, admin: admin}
  end

  describe "Mount & Access" do
    test "redirects and shows error if template does not exist", %{conn: conn} do
      fake_id = Ecto.UUID.generate()

      assert {:error, redirect} = live(conn, ~p"/studio/library/#{fake_id}/editor")

      assert {:live_redirect, %{to: "/studio/library"}} = redirect
    end

    test "redirects if user lacks library.read permission", %{conn: conn} do
      limited_role = insert(:role, permissions: [])
      limited_user = insert(:account, role: limited_role)
      conn = init_test_session(conn, %{"account_id" => limited_user.id})

      block = insert(:library_block, owner_id: limited_user.id)

      assert {:error, redirect} = live(conn, ~p"/studio/library/#{block.id}/editor")

      case redirect do
        {:redirect, %{to: _path}} -> assert true
        {:live_redirect, %{to: _path}} -> assert true
        _ -> flunk("Expected a redirect due to lack of permissions")
      end
    end

    test "redirects and shows error if user tries to edit someone else's template without sharing",
         %{conn: conn} do
      other_user = insert(:account)

      block = insert(:library_block, owner_id: other_user.id)

      assert {:error, redirect} = live(conn, ~p"/studio/library/#{block.id}/editor")

      assert {:live_redirect,
              %{
                to: "/studio/library",
                flash: %{"error" => "Template not found or access denied."}
              }} = redirect
    end

    test "renders editor successfully with template title", %{conn: conn, admin: admin} do
      block = insert(:library_block, title: "My Awesome Template", owner_id: admin.id)

      {:ok, _lv, html} = live(conn, ~p"/studio/library/#{block.id}/editor")

      assert html =~ "My Awesome Template"
      assert html =~ "General Settings"
      assert html =~ "Content Editor"
    end
  end

  describe "Inspector (Right Column)" do
    test "updates general settings (title and tags)", %{conn: conn, admin: admin} do
      block = insert(:library_block, title: "Old Title", tags: ["old"], owner_id: admin.id)

      {:ok, lv, _html} = live(conn, ~p"/studio/library/#{block.id}/editor")

      render_hook(lv, "update_meta", %{
        "library_block" => %{"title" => "Super New Title"},
        "tags_string" => "elixir, phoenix, awesome"
      })

      {:ok, updated_block} = Content.get_library_block(block.id)
      assert updated_block.title == "Super New Title"
      assert updated_block.tags == ["elixir", "phoenix", "awesome"]
    end

    test "updates advanced settings for quiz_exam with tags parsing", %{conn: conn, admin: admin} do
      block = insert(:library_block, type: :quiz_exam, owner_id: admin.id)

      {:ok, lv, _html} = live(conn, ~p"/studio/library/#{block.id}/editor")

      render_hook(lv, "update_meta", %{
        "library_block" => %{
          "content" => %{
            "count" => "25",
            "time_limit" => "60",
            "allowed_blur_attempts" => "5"
          }
        },
        "tags_mandatory" => "elixir, hard",
        "tags_include" => "medium",
        "tags_exclude" => "draft",
        "tags_string" => ""
      })

      {:ok, updated_block} = Content.get_library_block(block.id)
      assert updated_block.content["count"] == 25
      assert updated_block.content["time_limit"] == 60
      assert updated_block.content["allowed_blur_attempts"] == 5
      assert updated_block.content["mandatory_tags"] == ["elixir", "hard"]
      assert updated_block.content["include_tags"] == ["medium"]
      assert updated_block.content["exclude_tags"] == ["draft"]
    end

    test "updates advanced settings for code block", %{conn: conn, admin: admin} do
      block = insert(:library_block, type: :code, owner_id: admin.id)

      {:ok, lv, _html} = live(conn, ~p"/studio/library/#{block.id}/editor")

      render_hook(lv, "update_meta", %{
        "library_block" => %{
          "content" => %{"language" => "elixir"}
        },
        "tags_string" => ""
      })

      {:ok, updated_block} = Content.get_library_block(block.id)
      assert updated_block.content["language"] == "elixir"
    end
  end

  describe "Canvas Contextual Editors (Left Column)" do
    test "adds and removes quiz options", %{conn: conn, admin: admin} do
      block =
        insert(:library_block,
          type: :quiz_question,
          content: %{
            "question_type" => "multiple",
            "body" => %{"type" => "doc", "content" => [%{"type" => "paragraph"}]},
            "options" => [
              %{"id" => "opt1", "text" => "First Option", "is_correct" => false},
              %{"id" => "opt2", "text" => "Second Option", "is_correct" => false}
            ]
          },
          owner_id: admin.id
        )

      {:ok, lv, _html} = live(conn, ~p"/studio/library/#{block.id}/editor")

      render_hook(lv, "add_quiz_option", %{})

      {:ok, updated_block} = Content.get_library_block(block.id)
      assert length(updated_block.content["options"]) == 3
      render_hook(lv, "remove_quiz_option", %{"option_id" => "opt2"})

      {:ok, final_block} = Content.get_library_block(block.id)
      assert length(final_block.content["options"]) == 2
      assert hd(final_block.content["options"])["id"] == "opt1"
    end

    test "updates text block body via update_content event", %{conn: conn, admin: admin} do
      block =
        insert(:library_block,
          type: :text,
          content: %{"type" => "doc", "content" => [%{"type" => "paragraph"}]},
          owner_id: admin.id
        )

      {:ok, lv, _html} = live(conn, ~p"/studio/library/#{block.id}/editor")

      new_content = %{
        "type" => "doc",
        "content" => [
          %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "Hello"}]}
        ]
      }

      render_hook(lv, "update_content", %{"content" => new_content})

      {:ok, updated_block} = Content.get_library_block(block.id)
      assert updated_block.content == new_content
    end

    test "updates quiz_question body via update_content event", %{conn: conn, admin: admin} do
      block =
        insert(:library_block,
          type: :quiz_question,
          content: %{
            "question_type" => "open",
            "body" => %{"type" => "doc", "content" => [%{"type" => "paragraph"}]},
            "options" => []
          },
          owner_id: admin.id
        )

      {:ok, lv, _html} = live(conn, ~p"/studio/library/#{block.id}/editor")

      new_body = %{
        "type" => "doc",
        "content" => [
          %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "New question?"}]}
        ]
      }

      render_hook(lv, "update_content", %{"content" => new_body})

      {:ok, updated_block} = Content.get_library_block(block.id)
      assert updated_block.content["body"] == new_body
      assert updated_block.content["question_type"] == "open"
    end

    test "updates quiz correct_answer via update_quiz_content", %{conn: conn, admin: admin} do
      block =
        insert(:library_block,
          type: :quiz_question,
          content: %{
            "question_type" => "exact_match",
            "body" => %{"type" => "doc", "content" => [%{"type" => "paragraph"}]},
            "options" => [],
            "correct_answer" => ""
          },
          owner_id: admin.id
        )

      {:ok, lv, _html} = live(conn, ~p"/studio/library/#{block.id}/editor")

      render_hook(lv, "update_quiz_content", %{"correct_answer" => "flag{test123}"})

      {:ok, updated_block} = Content.get_library_block(block.id)
      assert updated_block.content["correct_answer"] == "flag{test123}"
    end
  end

  describe "Code Block Test Cases" do
    test "adds and removes test cases for code block", %{conn: conn, admin: admin} do
      block =
        insert(:library_block,
          type: :code,
          content: %{
            "language" => "python",
            "code" => "print('hello')",
            "test_cases" => []
          },
          owner_id: admin.id
        )

      {:ok, lv, _html} = live(conn, ~p"/studio/library/#{block.id}/editor")

      render_hook(lv, "add_test_case", %{})

      {:ok, updated_block} = Content.get_library_block(block.id)
      assert length(updated_block.content["test_cases"]) == 1
      assert hd(updated_block.content["test_cases"])["weight"] == 100

      render_hook(lv, "add_test_case", %{})

      {:ok, updated_block2} = Content.get_library_block(block.id)
      assert length(updated_block2.content["test_cases"]) == 2
      [tc1, tc2] = updated_block2.content["test_cases"]
      assert tc1["weight"] == 100
      assert tc2["weight"] == 0

      render_hook(lv, "remove_test_case", %{"tc_id" => tc1["id"]})

      {:ok, final_block} = Content.get_library_block(block.id)
      assert length(final_block.content["test_cases"]) == 1
      assert hd(final_block.content["test_cases"])["id"] == tc2["id"]
    end

    test "run_instructor_test shows error when no solution code", %{conn: conn, admin: admin} do
      block =
        insert(:library_block,
          type: :code,
          content: %{
            "language" => "python",
            "code" => "",
            "test_cases" => [%{"id" => "tc1", "input" => "", "expected_output" => "hello"}]
          },
          owner_id: admin.id
        )

      {:ok, lv, _html} = live(conn, ~p"/studio/library/#{block.id}/editor")

      html = render_hook(lv, "run_instructor_test", %{})
      assert html =~ "Please write a Reference Solution first!"
    end
  end

  describe "Media Upload Modal" do
    test "opens and closes media upload modal", %{conn: conn, admin: admin} do
      block = insert(:library_block, type: :image, owner_id: admin.id)

      {:ok, lv, _html} = live(conn, ~p"/studio/library/#{block.id}/editor")

      lv
      |> element(
        "button[phx-click='request_media_upload'][phx-value-media_type='image']",
        "Upload File"
      )
      |> render_click()

      assert render(lv) =~ "Upload Media"
      assert render(lv) =~ "Click or drag files here"

      lv
      |> element("button[phx-click='cancel_media_upload']")
      |> render_click()

      refute render(lv) =~ "Click or drag files here"
    end

    test "deletes an attachment from the file manager", %{conn: conn, admin: admin} do
      block =
        insert(:library_block,
          type: :attachment,
          content: %{
            "files" => [
              %{"name" => "Doc1.pdf", "url" => "/fake/url/1.pdf"},
              %{"name" => "Doc2.pdf", "url" => "/fake/url/2.pdf"}
            ]
          },
          owner_id: admin.id
        )

      {:ok, lv, _html} = live(conn, ~p"/studio/library/#{block.id}/editor")

      render_hook(lv, "delete_attachment", %{"url" => "/fake/url/1.pdf"})

      {:ok, updated_block} = Content.get_library_block(block.id)
      files = updated_block.content["files"]
      assert length(files) == 1
      assert hd(files)["url"] == "/fake/url/2.pdf"
    end
  end

  describe "Real-time Collaboration (PubSub)" do
    test "redirects when access is revoked via refresh_library message", %{
      conn: conn,
      admin: owner
    } do
      role_reader = insert(:role, permissions: ["library.read"])
      reader = insert(:account, role: role_reader)

      block = insert(:library_block, title: "Revoked Template", owner_id: owner.id)
      insert(:library_block_share, library_block: block, account_id: reader.id, role: :reader)

      reader_conn = init_test_session(conn, %{"account_id" => reader.id})
      {:ok, lv, _html} = live(reader_conn, ~p"/studio/library/#{block.id}/editor")

      Content.revoke_block_share(owner, block, reader.id)

      send(lv.pid, :refresh_library)

      assert_redirect(lv, "/studio/library")
    end

    test "shows flash when role changes via refresh_library message", %{
      conn: conn,
      admin: owner
    } do
      role_writer = insert(:role, permissions: ["library.read", "library.update"])
      writer = insert(:account, role: role_writer)

      block = insert(:library_block, title: "Upgraded Template", owner_id: owner.id)
      insert(:library_block_share, library_block: block, account_id: writer.id, role: :reader)

      writer_conn = init_test_session(conn, %{"account_id" => writer.id})
      {:ok, lv, _html} = live(writer_conn, ~p"/studio/library/#{block.id}/editor")

      Content.share_block(owner, block, writer.id, :writer)
      send(lv.pid, :refresh_library)

      Process.sleep(50)

      html = render(lv)
      assert html =~ "Your access level has been updated."
    end
  end

  describe "Collaborator Roles (Reader vs Writer)" do
    setup %{admin: owner} do
      role_reader = insert(:role, permissions: ["library.read"])
      reader = insert(:account, role: role_reader)

      role_writer = insert(:role, permissions: ["library.read", "library.update"])
      writer = insert(:account, role: role_writer)

      block = insert(:library_block, title: "Shared Template", owner_id: owner.id)

      insert(:library_block_share, library_block: block, account_id: reader.id, role: :reader)
      insert(:library_block_share, library_block: block, account_id: writer.id, role: :writer)

      %{block: block, reader: reader, writer: writer, owner: owner}
    end

    test "reader sees preview mode and no inspector", %{conn: conn, block: block, reader: reader} do
      reader_conn = init_test_session(conn, %{"account_id" => reader.id})
      {:ok, _lv, html} = live(reader_conn, ~p"/studio/library/#{block.id}/editor")

      assert html =~ block.title
      refute html =~ "Inspector"
      refute html =~ "General Settings"
      assert html =~ ~s(data-readonly="true")
    end

    test "reader is blocked from mutating events at the handler level", %{
      conn: conn,
      block: block,
      reader: reader
    } do
      reader_conn = init_test_session(conn, %{"account_id" => reader.id})
      {:ok, lv, _html} = live(reader_conn, ~p"/studio/library/#{block.id}/editor")

      render_hook(lv, "update_meta", %{
        "library_block" => %{"title" => "Hacked Title"},
        "tags_string" => ""
      })

      {:ok, unchanged_block} = Content.get_library_block(block.id)
      assert unchanged_block.title == "Shared Template"
    end

    test "reader is blocked from adding quiz options", %{conn: conn, owner: owner} do
      role_reader = insert(:role, permissions: ["library.read"])
      reader = insert(:account, role: role_reader)

      block =
        insert(:library_block,
          type: :quiz_question,
          content: %{
            "question_type" => "multiple",
            "body" => %{"type" => "doc", "content" => [%{"type" => "paragraph"}]},
            "options" => []
          },
          owner_id: owner.id
        )

      insert(:library_block_share, library_block: block, account_id: reader.id, role: :reader)

      reader_conn = init_test_session(conn, %{"account_id" => reader.id})
      {:ok, lv, _html} = live(reader_conn, ~p"/studio/library/#{block.id}/editor")

      render_hook(lv, "add_quiz_option", %{})

      {:ok, unchanged_block} = Content.get_library_block(block.id)
      assert unchanged_block.content["options"] == []
    end

    test "writer sees edit mode and inspector", %{conn: conn, block: block, writer: writer} do
      writer_conn = init_test_session(conn, %{"account_id" => writer.id})
      {:ok, _lv, html} = live(writer_conn, ~p"/studio/library/#{block.id}/editor")

      assert html =~ block.title
      assert html =~ "Inspector"
      assert html =~ "General Settings"
      assert html =~ ~s(name="library_block[title]")
    end

    test "writer can update template metadata", %{conn: conn, block: block, writer: writer} do
      writer_conn = init_test_session(conn, %{"account_id" => writer.id})
      {:ok, lv, _html} = live(writer_conn, ~p"/studio/library/#{block.id}/editor")

      render_hook(lv, "update_meta", %{
        "library_block" => %{"title" => "Updated by Writer"},
        "tags_string" => "new, tags"
      })

      {:ok, updated_block} = Content.get_library_block(block.id)
      assert updated_block.title == "Updated by Writer"
      assert updated_block.tags == ["new", "tags"]
    end
  end
end
