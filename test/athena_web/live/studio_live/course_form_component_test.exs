defmodule AthenaWeb.StudioLive.CourseFormComponentTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory
  alias Athena.Content

  setup %{conn: conn} do
    role = insert(:role, permissions: ["courses.read", "courses.create", "courses.update"])
    account = insert(:account, role: role)

    conn = init_test_session(conn, %{"account_id" => account.id})
    %{conn: conn, current_user: account}
  end

  describe "Course Form Component" do
    test "validates required fields on change", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/studio/courses/new")

      html =
        lv
        |> form("#course-form", %{
          "course" => %{"title" => ""}
        })
        |> render_change()

      assert html =~ "can&#39;t be blank"
    end

    test "validates title length on change", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/studio/courses/new")

      html =
        lv
        |> form("#course-form", %{
          "course" => %{"title" => "ab"}
        })
        |> render_change()

      assert html =~ "should be at least 3 character(s)"
    end

    test "creates a new course and assigns current user as owner", %{
      conn: conn,
      current_user: current_user
    } do
      {:ok, lv, _html} = live(conn, ~p"/studio/courses/new")

      lv
      |> form("#course-form", %{
        "course" => %{
          "title" => "Phoenix LiveView Mastery",
          "description" => "Learn how to build interactive apps.",
          "status" => "draft",
          "type" => "competition"
        }
      })
      |> render_submit()

      assert_patch(lv, ~p"/studio/courses")

      {:ok, {courses, _meta}} = Content.list_courses(current_user, %{})
      assert length(courses) == 1
      course = hd(courses)

      assert course.title == "Phoenix LiveView Mastery"
      assert course.description == "Learn how to build interactive apps."
      assert course.status == :draft
      assert course.type == :competition
      assert course.owner_id == current_user.id

      assert render(lv) =~ "Course created successfully"
    end

    test "updates an existing course", %{conn: conn, current_user: current_user} do
      course =
        insert(:course, title: "Old Course Title", owner_id: current_user.id, type: :standard)

      {:ok, lv, _html} = live(conn, ~p"/studio/courses/#{course.id}/edit")

      lv
      |> form("#course-form", %{
        "course" => %{
          "title" => "Updated Course Title",
          "status" => "published",
          "type" => "standard"
        }
      })
      |> render_submit()

      assert_patch(lv, ~p"/studio/courses")

      {:ok, updated_course} = Content.get_course(current_user, course.id)

      assert updated_course.title == "Updated Course Title"
      assert updated_course.status == :published
      assert updated_course.type == :standard
      assert render(lv) =~ "Course updated successfully"
    end
  end
end
