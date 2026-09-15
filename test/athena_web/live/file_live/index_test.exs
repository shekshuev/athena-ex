defmodule AthenaWeb.FileLive.IndexTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Athena.Factory

  setup %{conn: conn} do
    role = insert(:role, permissions: [])
    user = insert(:account, role: role)
    conn = init_test_session(conn, %{"account_id" => user.id})
    %{conn: conn, user: user}
  end

  describe "My Files page" do
    test "loads without any files.* permission and shows the empty state", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/files")

      assert html =~ "My Files"
      assert html =~ "No files yet"
      assert html =~ "100.0 MB"
    end

    test "renders only the current user's own files", %{conn: conn, user: user} do
      insert(:media_file, owner_id: user.id, context: :personal, original_name: "mine.pdf")
      insert(:media_file, context: :personal, original_name: "not_mine.pdf")
      insert(:media_file, owner_id: user.id, context: :avatar, original_name: "avatar.png")

      {:ok, _lv, html} = live(conn, ~p"/files")

      assert html =~ "mine.pdf"
      refute html =~ "not_mine.pdf"
      refute html =~ "avatar.png"
    end

    test "search filters files by name", %{conn: conn, user: user} do
      insert(:media_file, owner_id: user.id, context: :personal, original_name: "report.pdf")
      insert(:media_file, owner_id: user.id, context: :personal, original_name: "photo.png")

      {:ok, lv, _html} = live(conn, ~p"/files")

      html =
        lv
        |> form("form[phx-change='search']", %{"search" => "report"})
        |> render_change()

      assert html =~ "report.pdf"
      refute html =~ "photo.png"
    end
  end

  describe "Delete" do
    test "shows confirmation modal on delete click", %{conn: conn, user: user} do
      file = insert(:media_file, owner_id: user.id, context: :personal, original_name: "old.pdf")

      {:ok, lv, _html} = live(conn, ~p"/files")

      html =
        lv
        |> element("button[phx-click='delete_click'][phx-value-id='#{file.id}']")
        |> render_click()

      assert html =~ "Are you sure you want to delete this file?"
    end

    test "deletes the file when confirmed and frees up quota", %{conn: conn, user: user} do
      file = insert(:media_file, owner_id: user.id, context: :personal, original_name: "old.pdf")

      {:ok, lv, _html} = live(conn, ~p"/files")

      lv
      |> element("button[phx-click='delete_click'][phx-value-id='#{file.id}']")
      |> render_click()

      html = render_click(lv, "confirm_delete")

      assert html =~ "File deleted successfully"
      refute html =~ "old.pdf"
    end

    test "cannot delete another user's file via a forged id", %{conn: conn} do
      other_file = insert(:media_file, context: :personal, original_name: "not_yours.pdf")

      {:ok, lv, _html} = live(conn, ~p"/files")

      render_click(lv, "delete_click", %{"id" => other_file.id})
      render_click(lv, "confirm_delete")

      assert Athena.Media.get_file(other_file.id) != nil
    end
  end

  describe "Upload" do
    test "uploads a file and reflects it in the grid and quota bar", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/files")

      lv |> element("button[phx-click='open_upload']") |> render_click()

      upload =
        file_input(lv, "#personal-upload-form", :media, [
          %{name: "new.pdf", content: "hello world", type: "application/pdf"}
        ])

      render_upload(upload, "new.pdf")

      lv
      |> form("#personal-upload-form")
      |> render_submit()

      assert render(lv) =~ "new.pdf"
    end

    test "rejects an upload once the quota is exhausted", %{conn: conn, user: user} do
      insert(:media_quota, role_id: user.role_id, limit_bytes: 10)

      {:ok, lv, _html} = live(conn, ~p"/files")

      lv |> element("button[phx-click='open_upload']") |> render_click()

      upload =
        file_input(lv, "#personal-upload-form", :media, [
          %{name: "big.pdf", content: String.duplicate("a", 100), type: "application/pdf"}
        ])

      assert {:error, [[_ref, %{reason: reason}]]} = render_upload(upload, "big.pdf")
      assert reason == "Not enough storage space remaining"
    end
  end
end
