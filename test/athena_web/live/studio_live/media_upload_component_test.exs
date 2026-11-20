defmodule AthenaWeb.StudioLive.MediaUploadComponentTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Athena.Factory

  defmodule DummyLive do
    use AthenaWeb, :live_view

    def mount(_params, session, socket) do
      {:ok,
       Phoenix.Component.assign(socket,
         upload_type: session["upload_type"],
         block_id: session["block_id"],
         current_user: session["current_user"],
         course_id: session["course_id"],
         test_pid: session["test_pid"]
       )}
    end

    def render(assigns) do
      ~H"""
      <div>
        <.live_component
          module={AthenaWeb.StudioLive.MediaUploadComponent}
          id="media-uploader"
          upload_type={@upload_type}
          block_id={@block_id}
          current_user={@current_user}
          course_id={@course_id}
        />
      </div>
      """
    end

    def handle_info({AthenaWeb.StudioLive.MediaUploadComponent, _} = msg, socket) do
      send(socket.assigns.test_pid, msg)
      {:noreply, socket}
    end

    def handle_event("cancel_media_upload", _, socket) do
      send(socket.assigns.test_pid, :modal_cancelled)
      {:noreply, socket}
    end
  end

  setup %{conn: conn} do
    role = insert(:role, permissions: ["library.update", "courses.update"])
    admin = insert(:account, role: role)
    course = insert(:course, owner_id: admin.id)

    %{conn: conn, admin: admin, course: course}
  end

  defp render_dummy(conn, admin, course, upload_type) do
    live_isolated(conn, DummyLive,
      session: %{
        "upload_type" => upload_type,
        "block_id" => "fake_block_id",
        "current_user" => admin,
        "course_id" => course.id,
        "test_pid" => self()
      }
    )
  end

  describe "Initialization & UI Text" do
    test "renders correctly for images", %{conn: conn, admin: admin, course: course} do
      {:ok, _view, html} = render_dummy(conn, admin, course, "image")

      assert html =~ "Upload Media"
      assert html =~ "Images"
      assert html =~ "Max 25MB"
    end

    test "renders correctly for videos", %{conn: conn, admin: admin, course: course} do
      {:ok, _view, html} = render_dummy(conn, admin, course, "video")

      assert html =~ ".MP4, .MOV, .WEBM"
      assert html =~ "Max 2GB"
    end

    test "renders correctly for attachments", %{conn: conn, admin: admin, course: course} do
      {:ok, _view, html} = render_dummy(conn, admin, course, "attachment")

      assert html =~ "including 7z"
      assert html =~ "Max 2GB each"
    end
  end

  describe "File Selection & Validation" do
    test "shows file in the list after selection", %{conn: conn, admin: admin, course: course} do
      {:ok, view, _html} = render_dummy(conn, admin, course, "image")

      upload =
        file_input(view, "#upload-form", :media, [
          %{name: "test_image.jpg", content: "fake_data", type: "image/jpeg"}
        ])

      html = render_upload(upload, "test_image.jpg")

      assert html =~ "test_image.jpg"
      assert html =~ "Upload Files"
    end
  end

  describe "Cancellation & Closing" do
    test "cancels a single file entry", %{conn: conn, admin: admin, course: course} do
      {:ok, view, _html} = render_dummy(conn, admin, course, "attachment")

      upload =
        file_input(view, "#upload-form", :media, [
          %{name: "doc1.pdf", content: "fake_data", type: "application/pdf"}
        ])

      render_upload(upload, "doc1.pdf")

      view
      |> element("button[phx-click='cancel_entry']")
      |> render_click()

      refute render(view) =~ "doc1.pdf"
    end

    test "emits cancel_media_upload event when clicking Cancel button", %{
      conn: conn,
      admin: admin,
      course: course
    } do
      {:ok, view, _html} = render_dummy(conn, admin, course, "image")

      view
      |> element("button[phx-click='cancel_media_upload']")
      |> render_click()

      assert_receive :modal_cancelled
    end
  end

  test "saves a 7z submission when the browser sends no MIME type", %{
    conn: conn,
    admin: admin,
    course: course
  } do
    {:ok, view, _html} = render_dummy(conn, admin, course, "file_assignment")

    upload =
      file_input(view, "#upload-form", :media, [
        %{name: "solution.7z", content: "archive", type: ""}
      ])

    render_upload(upload, "solution.7z")
    view |> form("#upload-form") |> render_submit()

    assert_receive {AthenaWeb.StudioLive.MediaUploadComponent,
                    {:saved, "fake_block_id", "file_assignment", [{:ok, saved}]}}

    assert saved["mime"] == "application/x-7z-compressed"
    assert saved["name"] == "solution.7z"

    file = Athena.Repo.get_by!(Athena.Media.File, original_name: "solution.7z")
    assert file.context == :submission
    assert file.mime_type == saved["mime"]
  end

  describe "Save / Submit Event" do
    test "processes the upload and sends results to parent component", %{
      conn: conn,
      admin: admin,
      course: course
    } do
      {:ok, view, _html} = render_dummy(conn, admin, course, "image")

      upload =
        file_input(view, "#upload-form", :media, [
          %{name: "success.jpg", content: "fake_data", type: "image/jpeg"}
        ])

      render_upload(upload, "success.jpg")

      view
      |> form("#upload-form")
      |> render_submit()

      assert_receive {AthenaWeb.StudioLive.MediaUploadComponent,
                      {:saved, "fake_block_id", "image", _results}}
    end
  end
end
