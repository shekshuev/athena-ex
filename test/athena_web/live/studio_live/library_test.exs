defmodule AthenaWeb.StudioLive.LibraryTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory

  setup %{conn: conn} do
    role =
      insert(:role,
        permissions: ["library.read", "library.create", "library.update", "library.delete"]
      )

    admin = insert(:account, role: role)
    conn = init_test_session(conn, %{"account_id" => admin.id})
    %{conn: conn, admin: admin}
  end

  describe "Library page (Index)" do
    test "should render the library templates list in a table", %{conn: conn, admin: admin} do
      block = insert(:library_block, title: "Base Quiz Template", owner_id: admin.id)

      {:ok, _lv, html} = live(conn, ~p"/studio/library")

      assert html =~ "Library"
      assert html =~ "Create Template"
      assert html =~ block.title
      assert html =~ "hero-wrench-screwdriver"
    end

    test "should handle search functionality", %{conn: conn, admin: admin} do
      insert(:library_block, title: "Python Basics Exam", owner_id: admin.id)
      insert(:library_block, title: "Elixir Advanced", owner_id: admin.id)

      {:ok, lv, _html} = live(conn, ~p"/studio/library")

      html =
        lv
        |> form("form[phx-change='search']", %{"search" => "Python"})
        |> render_change()

      assert html =~ "Python Basics Exam"
      refute html =~ "Elixir Advanced"
    end
  end

  describe "Library page (Create/Edit actions)" do
    test "should open the create template slide-over via URL", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/studio/library/new")

      assert html =~ "Create Template"
      assert html =~ "Title"
      assert html =~ "Tags (comma separated)"
    end

    test "should open the edit metadata slide-over via URL", %{conn: conn, admin: admin} do
      block = insert(:library_block, title: "Target Template", owner_id: admin.id)

      {:ok, _lv, html} = live(conn, ~p"/studio/library/#{block.id}/edit")

      assert html =~ "Edit Template"
      assert html =~ "Target Template"
    end
  end

  describe "Library page (Delete action)" do
    test "should show confirmation modal on delete click", %{conn: conn, admin: admin} do
      block = insert(:library_block, title: "Doomed Template", owner_id: admin.id)

      {:ok, lv, _html} = live(conn, ~p"/studio/library")

      html =
        lv
        |> element("button[phx-click='delete_click'][phx-value-id='#{block.id}']")
        |> render_click()

      assert html =~ "permanently delete this template"
    end

    test "should delete the template when confirmed", %{conn: conn, admin: admin} do
      block = insert(:library_block, title: "Doomed Template", owner_id: admin.id)

      {:ok, lv, _html} = live(conn, ~p"/studio/library")

      lv
      |> element("button[phx-click='delete_click'][phx-value-id='#{block.id}']")
      |> render_click()

      html = render_click(lv, "confirm_delete")

      assert html =~ "Template deleted successfully"
      refute html =~ "Doomed Template"
    end
  end

  describe "Permissions & ACL" do
    setup %{conn: conn} do
      role = insert(:role, permissions: ["library.read"])
      limited_user = insert(:account, role: role)
      conn = init_test_session(conn, %{"account_id" => limited_user.id})

      %{conn: conn, limited_user: limited_user}
    end

    test "should not see action buttons if user only has read permission", %{
      conn: conn
    } do
      insert(:library_block, owner_id: Ecto.UUID.generate(), is_public: true)

      {:ok, _lv, html} = live(conn, ~p"/studio/library")

      assert html =~ "Library"
      refute html =~ "Create Template"
      refute html =~ "hero-pencil-square"
      refute html =~ "hero-trash"
      refute html =~ "hero-share"
      assert html =~ "hero-eye"
    end

    test "should redirect from /new if user lacks create permission", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/studio/library"}}} =
               live(conn, ~p"/studio/library/new")
    end

    test "should redirect from /edit if user lacks update permission", %{
      conn: conn
    } do
      target = insert(:library_block, owner_id: Ecto.UUID.generate(), is_public: true)

      assert {:error, {:live_redirect, %{to: "/studio/library"}}} =
               live(conn, ~p"/studio/library/#{target.id}/edit")
    end

    test "should show error flash on delete_click if user lacks delete permission", %{
      conn: conn
    } do
      target = insert(:library_block, owner_id: Ecto.UUID.generate(), is_public: true)
      {:ok, lv, _html} = live(conn, ~p"/studio/library")

      html = render_click(lv, "delete_click", %{"id" => target.id})

      assert html =~ "Only the owner can delete this template."
    end

    test "can access Editor in preview mode for public blocks", %{conn: conn} do
      target = insert(:library_block, owner_id: Ecto.UUID.generate(), is_public: true)
      {:ok, _lv, html} = live(conn, ~p"/studio/library/#{target.id}/editor")
      assert html =~ target.title
    end
  end

  describe "Collaborator Roles (Reader vs Writer)" do
    setup %{admin: owner} do
      role = insert(:role, permissions: ["library.read"])
      collaborator = insert(:account, role: role)

      block = insert(:library_block, title: "Collab Block", owner_id: owner.id)

      %{block: block, collaborator: collaborator}
    end

    test "reader sees only view button and enters read-only preview mode", %{
      conn: conn,
      block: block,
      collaborator: reader
    } do
      insert(:library_block_share, library_block: block, account_id: reader.id, role: :reader)
      reader_conn = init_test_session(conn, %{"account_id" => reader.id})

      {:ok, lv_index, html_index} = live(reader_conn, ~p"/studio/library")

      assert html_index =~ block.title
      assert html_index =~ "hero-eye"
      refute html_index =~ "hero-wrench-screwdriver"
      refute html_index =~ "hero-pencil-square"
      refute html_index =~ "hero-share"
      refute html_index =~ "hero-trash"

      lv_index
      |> element("a[title='View Template']")
      |> render_click()

      {:ok, _lv_editor, html_editor} = live(reader_conn, ~p"/studio/library/#{block.id}/editor")

      assert html_editor =~ block.title
      refute html_editor =~ "Inspector"
      refute html_editor =~ "Template Settings"
      assert html_editor =~ "data-readonly=\"true\""
    end

    test "writer sees edit buttons and has access to inspector", %{
      conn: conn,
      block: block,
      collaborator: writer
    } do
      insert(:library_block_share, library_block: block, account_id: writer.id, role: :writer)
      writer_conn = init_test_session(conn, %{"account_id" => writer.id})

      {:ok, lv_index, html_index} = live(writer_conn, ~p"/studio/library")

      assert html_index =~ block.title
      assert html_index =~ "hero-wrench-screwdriver"
      assert html_index =~ "hero-pencil-square"
      refute html_index =~ "hero-share"
      refute html_index =~ "hero-trash"

      lv_index
      |> element("a[title='Open Editor']")
      |> render_click()

      {:ok, _lv_editor, html_editor} = live(writer_conn, ~p"/studio/library/#{block.id}/editor")

      assert html_editor =~ block.title
      assert html_editor =~ "Inspector"
      assert html_editor =~ "Template Settings"
    end
  end
end
