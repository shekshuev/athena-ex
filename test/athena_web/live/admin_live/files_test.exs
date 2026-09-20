defmodule AthenaWeb.AdminLive.FilesTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory

  setup %{conn: conn} do
    role =
      insert(:role,
        permissions: ["admin", "files.read", "files.delete", "files.update"]
      )

    admin = insert(:account, role: role)
    conn = init_test_session(conn, %{"account_id" => admin.id})
    %{conn: conn, admin: admin}
  end

  describe "Files page (Index)" do
    test "renders the files list", %{conn: conn} do
      file = insert(:media_file, original_name: "report.pdf")

      {:ok, _lv, html} = live(conn, ~p"/admin/files")

      assert html =~ "System Files"
      assert html =~ "Storage Quotas by Role"
      assert html =~ file.original_name
    end

    test "the download link keeps the key's slashes literal instead of %2F-encoding them", %{
      conn: conn
    } do
      file = insert(:media_file, original_name: "report.pdf")

      {:ok, _lv, html} = live(conn, ~p"/admin/files")

      refute html =~ "%2F"
      assert html =~ ~s(href="/media/#{file.key}")
    end

    test "handles search functionality and maintains params", %{conn: conn} do
      insert(:media_file, original_name: "special_report.pdf")
      insert(:media_file, original_name: "common_notes.txt")

      {:ok, lv, _html} = live(conn, ~p"/admin/files")

      html =
        lv
        |> form("form[phx-change='search']", %{"search" => "special"})
        |> render_change()

      assert html =~ "special_report.pdf"
      refute html =~ "common_notes.txt"

      assert_patched(
        lv,
        ~p"/admin/files?order_by[]=inserted_at&order_directions[]=desc&page=1&page_size=10&search=special"
      )
    end

    test "filters by context", %{conn: conn} do
      insert(:media_file, original_name: "personal_doc.pdf", context: :personal)
      insert(:media_file, original_name: "avatar.png", context: :avatar)

      {:ok, lv, _html} = live(conn, ~p"/admin/files")

      html =
        lv
        |> form("form[phx-change='filter_context']", %{"context" => "avatar"})
        |> render_change()

      assert html =~ "avatar.png"
      refute html =~ "personal_doc.pdf"
    end
  end

  describe "Files page (Pagination & Sorting)" do
    test "changes page size and updates URL", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/files")

      lv
      |> form("form[phx-change='update_page_size']", %{"page_size" => "50"})
      |> render_change()

      assert_patched(
        lv,
        ~p"/admin/files?order_by[]=inserted_at&order_directions[]=desc&page=1&page_size=50"
      )
    end

    test "sorts by size when column header is clicked", %{conn: conn} do
      insert(:media_file, original_name: "small.pdf", size: 10)
      insert(:media_file, original_name: "large.pdf", size: 10_000_000)

      {:ok, lv, _html} = live(conn, ~p"/admin/files")

      lv
      |> element("a", "Size")
      |> render_click()

      assert_patched(
        lv,
        ~p"/admin/files?order_by[]=size&order_directions[]=asc&page=1&page_size=10"
      )
    end
  end

  describe "Files page (Delete action)" do
    test "deletes the file when confirmed", %{conn: conn} do
      file = insert(:media_file, original_name: "doomed.pdf")

      {:ok, lv, _html} = live(conn, ~p"/admin/files")

      lv
      |> element("button[phx-click='delete_click'][phx-value-id='#{file.id}']")
      |> render_click()

      html = render_click(lv, "confirm_delete")

      assert html =~ "File deleted successfully"
      refute html =~ "doomed.pdf"
    end
  end

  describe "Quota management panel" do
    test "shows per-role usage and limit", %{conn: conn, admin: admin} do
      insert(:media_quota, role_id: admin.role_id, limit_bytes: 20_000_000)
      insert(:media_file, owner_id: admin.id, context: :personal, size: 5_000_000)

      {:ok, _lv, html} = live(conn, ~p"/admin/files")

      assert html =~ admin.role.name
      assert html =~ "4.8 MB"
      assert html =~ "19.1 MB"
    end

    test "edits a role's quota", %{conn: conn, admin: admin} do
      {:ok, lv, _html} = live(conn, ~p"/admin/files")

      lv
      |> element("button[phx-click='edit_quota_click'][phx-value-role-id='#{admin.role_id}']")
      |> render_click()

      html =
        lv
        |> form("#quota-edit-modal form", %{"limit_mb" => "42"})
        |> render_submit()

      assert html =~ "Storage quota updated successfully"

      quota = Athena.Repo.get(Athena.Media.Quota, admin.role_id)
      assert quota.limit_bytes == 42 * 1024 * 1024
    end
  end

  describe "Permissions & ACL" do
    test "user without files.read is redirected away from the page", %{conn: conn} do
      role = insert(:role, permissions: [])
      limited_user = insert(:account, role: role)
      conn = init_test_session(conn, %{"account_id" => limited_user.id})

      assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/admin/files")
    end

    test "user without files.delete cannot trigger delete_click", %{conn: conn} do
      role = insert(:role, permissions: ["files.read"])
      limited_user = insert(:account, role: role)
      conn = init_test_session(conn, %{"account_id" => limited_user.id})

      target = insert(:media_file)
      {:ok, lv, _html} = live(conn, ~p"/admin/files")

      html = render_click(lv, "delete_click", %{"id" => target.id})

      assert html =~ "You don&#39;t have permission to delete files."
    end

    test "user without files.update cannot trigger edit_quota_click", %{conn: conn} do
      role = insert(:role, permissions: ["files.read"])
      limited_user = insert(:account, role: role)
      conn = init_test_session(conn, %{"account_id" => limited_user.id})

      {:ok, lv, _html} = live(conn, ~p"/admin/files")

      refute has_element?(lv, "button[phx-click='edit_quota_click']")

      html = render_click(lv, "edit_quota_click", %{"role-id" => limited_user.role_id})

      assert html =~ "You don&#39;t have permission to edit storage quotas."
    end
  end
end
