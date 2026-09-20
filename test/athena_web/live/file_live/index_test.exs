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

    test "the download link keeps the key's slashes literal instead of %2F-encoding them", %{
      conn: conn,
      user: user
    } do
      # Regression: `~p"/media/#{file.key}"` treats the whole key as one
      # opaque path segment and percent-encodes its slashes to `%2F`. Every
      # personal file's key looks like "personal/<uuid>/<name>" (see
      # `Media.prepare_personal_upload/2`), so this broke the Download
      # button for every personal file - `Plug.Static` decodes `%2F` back
      # to `/` and then rejects the resulting segment as an invalid path
      # (`Plug.Static.InvalidPathError`) before the request ever reaches
      # `MediaController`. The fix is the same "split into segments" trick
      # already used everywhere else `~p"/media/#{...}"` is built.
      file = insert(:media_file, owner_id: user.id, context: :personal, original_name: "mine.pdf")

      {:ok, _lv, html} = live(conn, ~p"/files")

      refute html =~ "%2F"
      assert html =~ ~s(href="/media/#{file.key}")

      conn = get(conn, "/media/#{file.key}")
      assert redirected_to(conn, 302) =~ file.key
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

  describe "Sharing" do
    test "opens the share modal for one's own file", %{conn: conn, user: user} do
      file = insert(:media_file, owner_id: user.id, context: :personal, original_name: "mine.pdf")

      {:ok, lv, _html} = live(conn, ~p"/files")

      html =
        lv
        |> element("button[phx-click='share_click'][phx-value-id='#{file.id}']")
        |> render_click()

      assert html =~ "Share File: mine.pdf"
      assert html =~ "Public Access"
    end

    test "cannot open the share modal for another user's file via a forged id", %{conn: conn} do
      other_file = insert(:media_file, context: :personal, original_name: "not_yours.pdf")

      {:ok, lv, _html} = live(conn, ~p"/files")

      html = render_click(lv, "share_click", %{"id" => other_file.id})

      assert html =~ "File not found"
      refute html =~ "Public Access"
    end

    test "toggling public access is reflected on the file card", %{conn: conn, user: user} do
      file = insert(:media_file, owner_id: user.id, context: :personal, original_name: "mine.pdf")

      {:ok, lv, _html} = live(conn, ~p"/files")

      lv
      |> element("button[phx-click='share_click'][phx-value-id='#{file.id}']")
      |> render_click()

      lv
      |> element("##{"share-#{file.id}"} form[phx-change='toggle_public']")
      |> render_change(%{"is_public" => "true"})

      assert render(lv) =~ "Public"
      assert Athena.Media.get_file(file.id).is_public
    end

    test "sharing with another user grants them access under 'Shared with me'", %{
      conn: conn,
      user: user
    } do
      other = insert(:account)
      other_conn = init_test_session(build_conn(), %{"account_id" => other.id})

      file = insert(:media_file, owner_id: user.id, context: :personal, original_name: "mine.pdf")

      {:ok, lv, _html} = live(conn, ~p"/files")

      lv
      |> element("button[phx-click='share_click'][phx-value-id='#{file.id}']")
      |> render_click()

      share_component_id = "share-#{file.id}"

      lv
      |> element("##{share_component_id} form[phx-change='search_users']")
      |> render_change(%{"query" => other.login})

      lv
      |> element(
        "##{share_component_id} button[phx-click='add_share'][phx-value-account_id='#{other.id}']"
      )
      |> render_click()

      html = render(lv)
      assert html =~ Athena.Identity.display_name(other)
      # "badge-secondary" is the "Shared" badge on the file card (as opposed
      # to "badge-primary" for "Public") - a real class check instead of
      # matching on the word "Shared", which the open share modal's own
      # "Shared with" divider would also contain.
      assert html =~ "badge-secondary"

      {:ok, _shared_lv, shared_html} = live(other_conn, ~p"/files?tab=shared")
      assert shared_html =~ "mine.pdf"
    end

    test "revoking access removes the file from 'Shared with me'", %{conn: conn, user: user} do
      other = insert(:account)
      file = insert(:media_file, owner_id: user.id, context: :personal, original_name: "mine.pdf")
      insert(:file_share, media_file: file, account_id: other.id)

      other_conn = init_test_session(build_conn(), %{"account_id" => other.id})
      {:ok, _lv, shared_html} = live(other_conn, ~p"/files?tab=shared")
      assert shared_html =~ "mine.pdf"

      {:ok, lv, _html} = live(conn, ~p"/files")

      lv
      |> element("button[phx-click='share_click'][phx-value-id='#{file.id}']")
      |> render_click()

      share_component_id = "share-#{file.id}"

      lv
      |> element(
        "##{share_component_id} button[phx-click='remove_share_click'][phx-value-account_id='#{other.id}']"
      )
      |> render_click()

      lv
      |> element("##{share_component_id}-remove-share-modal button", "Revoke")
      |> render_click()

      refute render(lv) =~ "badge-secondary"

      {:ok, _lv2, shared_html2} = live(other_conn, ~p"/files?tab=shared")
      refute shared_html2 =~ "mine.pdf"
    end

    test "a public file shows only the 'Public' badge, not also 'Shared'", %{
      conn: conn,
      user: user
    } do
      other = insert(:account)

      file =
        insert(:media_file,
          owner_id: user.id,
          context: :personal,
          original_name: "mine.pdf",
          is_public: true
        )

      insert(:file_share, media_file: file, account_id: other.id)

      {:ok, _lv, html} = live(conn, ~p"/files")

      assert html =~ "badge-primary"
      refute html =~ "badge-secondary"
    end

    test "a public file shows up under 'Shared with me' for other users", %{conn: conn} do
      other = insert(:account)

      insert(:media_file,
        owner_id: other.id,
        context: :personal,
        original_name: "public.pdf",
        is_public: true
      )

      {:ok, _lv, html} = live(conn, ~p"/files?tab=shared")
      assert html =~ "public.pdf"
    end

    test "'Shared with me' never shows the viewer's own files, even if shared with self", %{
      conn: conn,
      user: user
    } do
      insert(:media_file, owner_id: user.id, context: :personal, original_name: "mine_only.pdf")

      {:ok, _lv, html} = live(conn, ~p"/files?tab=shared")
      refute html =~ "mine_only.pdf"
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
