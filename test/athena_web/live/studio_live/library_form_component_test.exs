defmodule AthenaWeb.StudioLive.LibraryFormComponentTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory
  alias Athena.Content

  setup %{conn: conn} do
    role = insert(:role, permissions: ["library.read", "library.create", "library.update"])
    account = insert(:account, role: role)

    conn = init_test_session(conn, %{"account_id" => account.id})
    %{conn: conn, current_user: account}
  end

  describe "Library Form Component" do
    test "validates required fields on change", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/studio/library/new")

      html =
        lv
        |> form("#library-form", %{
          "library_block" => %{"title" => ""},
          "tags_string" => ""
        })
        |> render_change()

      assert html =~ "can&#39;t be blank"
    end

    test "validates title length on change", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/studio/library/new")

      html =
        lv
        |> form("#library-form", %{
          "library_block" => %{"title" => "ab"},
          "tags_string" => ""
        })
        |> render_change()

      assert html =~ "should be at least 3 character(s)"
    end

    test "creates a new template with parsed tags and assigns current user as owner", %{
      conn: conn,
      current_user: current_user
    } do
      {:ok, lv, _html} = live(conn, ~p"/studio/library/new")

      lv
      |> form("#library-form", %{
        "library_block" => %{
          "title" => "New Exam Question",
          "type" => "quiz_question"
        },
        "tags_string" => "elixir, hard, core"
      })
      |> render_submit()

      assert_patch(lv, ~p"/studio/library")

      {:ok, {blocks, _meta}} = Content.list_library_blocks(%{}, current_user.id)
      assert length(blocks) == 1
      block = hd(blocks)

      assert block.title == "New Exam Question"
      assert block.type == :quiz_question
      assert block.tags == ["elixir", "hard", "core"]
      assert block.owner_id == current_user.id

      assert render(lv) =~ "Template created successfully"
    end

    test "updates an existing template and its tags", %{conn: conn, current_user: current_user} do
      block = insert(:library_block, title: "Old Title", tags: ["old"], owner_id: current_user.id)

      {:ok, lv, _html} = live(conn, ~p"/studio/library/#{block.id}/edit")

      lv
      |> form("#library-form", %{
        "library_block" => %{
          "title" => "Updated Title"
        },
        "tags_string" => "new, tag"
      })
      |> render_submit()

      assert_patch(lv, ~p"/studio/library")

      {:ok, updated_block} = Content.get_library_block(block.id)

      assert updated_block.title == "Updated Title"
      assert updated_block.tags == ["new", "tag"]
      assert render(lv) =~ "Template updated successfully"
    end
  end
end
