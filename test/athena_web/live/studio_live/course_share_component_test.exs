defmodule AthenaWeb.StudioLive.CourseShareComponentTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Athena.Factory

  defmodule DummyLive do
    use AthenaWeb, :live_view

    def mount(_params, session, socket) do
      {:ok,
       Phoenix.Component.assign(socket,
         current_user: session["current_user"],
         course: session["course"],
         test_pid: session["test_pid"]
       )}
    end

    def render(assigns) do
      ~H"""
      <div>
        <.live_component
          module={AthenaWeb.StudioLive.CourseShareComponent}
          id="share-modal"
          course={@course}
          current_user={@current_user}
        />
      </div>
      """
    end

    def handle_info({AthenaWeb.StudioLive.CourseShareComponent, _} = msg, socket) do
      send(socket.assigns.test_pid, msg)
      {:noreply, socket}
    end
  end

  setup %{conn: conn} do
    role = insert(:role, permissions: ["courses.update", "users.read"])
    admin = insert(:account, role: role, login: "admin_user")
    course = insert(:course, owner_id: admin.id, is_public: false)

    %{conn: conn, admin: admin, course: course}
  end

  defp render_dummy(conn, admin, course) do
    live_isolated(conn, DummyLive,
      session: %{
        "current_user" => admin,
        "course" => course,
        "test_pid" => self()
      }
    )
  end

  describe "Initialization & UI Text" do
    test "renders correctly", %{conn: conn, admin: admin, course: course} do
      {:ok, _view, html} = render_dummy(conn, admin, course)

      assert html =~ "Public Access"
      assert html =~ "Collaborators"
      assert html =~ "This course is currently private."
    end
  end

  describe "Public Access Toggle" do
    test "toggles public access and sends message to parent", %{
      conn: conn,
      admin: admin,
      course: course
    } do
      {:ok, view, _html} = render_dummy(conn, admin, course)

      view
      |> element("#share-modal form[phx-change='toggle_public']")
      |> render_change(%{"is_public" => "true"})

      assert_receive {AthenaWeb.StudioLive.CourseShareComponent,
                      {:updated, %Athena.Content.Course{is_public: true}}}
    end
  end

  describe "Searching Users" do
    test "searches and displays user logins", %{conn: conn, admin: admin, course: course} do
      target = insert(:account, login: "target_student")
      {:ok, view, _html} = render_dummy(conn, admin, course)

      html =
        view
        |> element("#share-modal form[phx-change='search_users']")
        |> render_change(%{"query" => "target"})

      assert html =~ target.login
      assert html =~ "+ Reader"
      assert html =~ "+ Writer"
    end
  end

  describe "Managing Shares" do
    test "adds a user as reader, changes role to writer, and revokes access", %{
      conn: conn,
      admin: admin,
      course: course
    } do
      target = insert(:account, login: "collab_user")
      {:ok, view, _html} = render_dummy(conn, admin, course)

      view
      |> element("#share-modal form[phx-change='search_users']")
      |> render_change(%{"query" => "collab"})

      html =
        view
        |> element(
          "button[phx-click='add_share'][phx-value-account_id='#{target.id}'][phx-value-role='reader']"
        )
        |> render_click()

      assert html =~ target.login
      assert html =~ "value=\"reader\" selected"

      html =
        view
        |> element("#share-modal form[phx-change='change_role']")
        |> render_change(%{"account_id" => target.id, "role" => "writer"})

      assert html =~ "value=\"writer\" selected"

      html =
        view
        |> element("button[phx-click='remove_share'][phx-value-account_id='#{target.id}']")
        |> render_click()

      refute html =~ target.login
      assert html =~ "This course is currently private."
    end
  end
end
