defmodule Athena.Content.CoursesTest do
  use Athena.DataCase, async: true

  alias Athena.Content.Courses
  alias Athena.Content.Course
  import Athena.Factory

  setup do
    admin_role =
      insert(:role,
        permissions: [
          "admin",
          "courses.read",
          "courses.create",
          "courses.update",
          "courses.delete"
        ]
      )

    admin = insert(:account, role: admin_role)

    instructor_role =
      insert(:role,
        permissions: ["courses.read", "courses.create", "courses.update", "courses.delete"],
        policies: %{
          "courses.read" => ["own_only"],
          "courses.update" => ["own_only"],
          "courses.delete" => ["own_only"]
        }
      )

    instructor = insert(:account, role: instructor_role)
    other_instructor = insert(:account, role: instructor_role)

    student = insert(:account, role: insert(:role, permissions: []))

    %{
      admin: admin,
      instructor: instructor,
      other_instructor: other_instructor,
      student: student
    }
  end

  describe "list_courses/2 (With ACL)" do
    test "returns a paginated list of all active courses for admin", %{admin: admin} do
      insert_list(3, :course)

      {:ok, {courses, meta}} = Courses.list_courses(admin, %{"page" => 1, "page_size" => 2})

      assert length(courses) == 2
      assert meta.total_count == 3
    end

    test "excludes soft-deleted courses from the list", %{admin: admin} do
      active_course = insert(:course)
      insert(:course, deleted_at: DateTime.utc_now())

      {:ok, {courses, _meta}} = Courses.list_courses(admin, %{})

      assert length(courses) == 1
      assert hd(courses).id == active_course.id
    end

    test "applies own_only policy and returns only instructor's courses", %{
      instructor: instructor,
      other_instructor: other_instructor
    } do
      my_course = insert(:course, owner_id: instructor.id)
      _other_course = insert(:course, owner_id: other_instructor.id)

      {:ok, {courses, meta}} = Courses.list_courses(instructor, %{})

      assert length(courses) == 1
      assert hd(courses).id == my_course.id
      assert meta.total_count == 1
    end
  end

  describe "list_accessible_course_ids/1" do
    test "returns all active course IDs for admin", %{admin: admin} do
      course1 = insert(:course)
      course2 = insert(:course)
      insert(:course, deleted_at: DateTime.utc_now())

      ids = Courses.list_accessible_course_ids(admin)

      assert length(ids) >= 2
      assert course1.id in ids
      assert course2.id in ids
    end

    test "returns only owned course IDs for instructor", %{
      instructor: instructor,
      other_instructor: other_instructor
    } do
      my_course = insert(:course, owner_id: instructor.id)
      _other_course = insert(:course, owner_id: other_instructor.id)

      ids = Courses.list_accessible_course_ids(instructor)

      assert ids == [my_course.id]
    end
  end

  describe "get_course/1 (Without ACL - Internal/Student)" do
    test "returns the course if it exists and is not deleted" do
      course = insert(:course)

      assert {:ok, fetched_course} = Courses.get_course(course.id)
      assert fetched_course.id == course.id
    end

    test "returns error if course is soft-deleted" do
      course = insert(:course, deleted_at: DateTime.utc_now())

      assert {:error, :not_found} = Courses.get_course(course.id)
    end

    test "returns error if course does not exist" do
      assert {:error, :not_found} = Courses.get_course(Ecto.UUID.generate())
    end
  end

  describe "get_course/2 (With ACL - Studio)" do
    test "returns course if user has admin permissions", %{admin: admin} do
      course = insert(:course)
      assert {:ok, fetched_course} = Courses.get_course(admin, course.id)
      assert fetched_course.id == course.id
    end

    test "returns course if instructor owns it", %{instructor: instructor} do
      course = insert(:course, owner_id: instructor.id)
      assert {:ok, fetched_course} = Courses.get_course(instructor, course.id)
      assert fetched_course.id == course.id
    end

    test "returns not_found error if instructor does not own the course", %{
      instructor: instructor,
      other_instructor: other_instructor
    } do
      course = insert(:course, owner_id: other_instructor.id)
      assert {:error, :not_found} = Courses.get_course(instructor, course.id)
    end
  end

  describe "create_course/2" do
    test "creates a course with valid attributes and auto-sets owner", %{admin: admin} do
      attrs = %{"title" => "Elixir for Pro", "description" => "Deep dive"}

      assert {:ok, %Course{} = course} = Courses.create_course(admin, attrs)
      assert course.title == "Elixir for Pro"
      assert course.status == :draft
      assert course.owner_id == admin.id
    end

    test "returns error changeset with invalid attributes", %{admin: admin} do
      assert {:error, changeset} = Courses.create_course(admin, %{"title" => ""})
      assert "can't be blank" in errors_on(changeset).title
    end

    test "enforces unique title constraint", %{admin: admin} do
      insert(:course, title: "Unique Course")

      assert {:error, changeset} =
               Courses.create_course(admin, %{"title" => "Unique Course"})

      assert "has already been taken" in errors_on(changeset).title
    end

    test "returns unauthorized if user lacks create permission", %{student: student} do
      assert {:error, :unauthorized} =
               Courses.create_course(student, %{"title" => "Hacked Course"})
    end
  end

  describe "update_course/3" do
    test "updates course attributes", %{admin: admin} do
      course = insert(:course, title: "Old Title")

      assert {:ok, updated} = Courses.update_course(admin, course, %{"title" => "New Title"})
      assert updated.title == "New Title"
    end

    test "returns error changeset for invalid update", %{admin: admin} do
      course = insert(:course)

      assert {:error, changeset} = Courses.update_course(admin, course, %{"title" => "ab"})
      assert "should be at least 3 character(s)" in errors_on(changeset).title
    end

    test "instructor can update their own course", %{instructor: instructor} do
      course = insert(:course, owner_id: instructor.id)

      assert {:ok, updated} =
               Courses.update_course(instructor, course, %{"title" => "My Updated Course"})

      assert updated.title == "My Updated Course"
    end

    test "returns unauthorized if instructor tries to update someone else's course", %{
      instructor: instructor,
      other_instructor: other
    } do
      course = insert(:course, owner_id: other.id)

      assert {:error, :unauthorized} =
               Courses.update_course(instructor, course, %{"title" => "Hacked"})
    end
  end

  describe "soft_delete_course/2" do
    test "sets deleted_at timestamp", %{admin: admin} do
      course = insert(:course)

      assert {:ok, deleted_course} = Courses.soft_delete_course(admin, course)
      assert deleted_course.deleted_at != nil

      assert {:error, :not_found} = Courses.get_course(course.id)
    end

    test "instructor can delete their own course", %{instructor: instructor} do
      course = insert(:course, owner_id: instructor.id)
      assert {:ok, deleted} = Courses.soft_delete_course(instructor, course)
      assert deleted.deleted_at != nil
    end

    test "returns unauthorized if instructor tries to delete someone else's course", %{
      instructor: instructor,
      other_instructor: other
    } do
      course = insert(:course, owner_id: other.id)
      assert {:error, :unauthorized} = Courses.soft_delete_course(instructor, course)
    end
  end

  describe "get_courses_map/1" do
    test "returns a map of active courses keyed by their IDs" do
      course1 = insert(:course)
      course2 = insert(:course)
      _unrelated_course = insert(:course)

      result = Courses.get_courses_map([course1.id, course2.id])

      assert is_map(result)
      assert map_size(result) == 2
      assert Map.has_key?(result, course1.id)
      assert Map.has_key?(result, course2.id)
      assert result[course1.id].title == course1.title
    end

    test "ignores non-existent IDs" do
      course = insert(:course)
      fake_id = Ecto.UUID.generate()

      result = Courses.get_courses_map([course.id, fake_id])

      assert map_size(result) == 1
      assert Map.has_key?(result, course.id)
      refute Map.has_key?(result, fake_id)
    end

    test "excludes soft-deleted courses" do
      active_course = insert(:course)
      deleted_course = insert(:course, deleted_at: DateTime.utc_now(:second))

      result = Courses.get_courses_map([active_course.id, deleted_course.id])

      assert map_size(result) == 1
      assert Map.has_key?(result, active_course.id)
      refute Map.has_key?(result, deleted_course.id)
    end

    test "returns an empty map for an empty list" do
      assert Courses.get_courses_map([]) == %{}
    end
  end

  describe "search_courses_by_title/3" do
    test "returns courses matching the title query (case-insensitive)", %{admin: admin} do
      course1 = insert(:course, title: "Advanced Elixir")
      course2 = insert(:course, title: "Elixir Basics")
      _course3 = insert(:course, title: "Ruby on Rails")

      results = Courses.search_courses_by_title(admin, "elixir")

      assert length(results) == 2
      ids = Enum.map(results, & &1.id)
      assert course1.id in ids
      assert course2.id in ids
    end

    test "respects the provided limit", %{admin: admin} do
      insert(:course, title: "Test Course 1")
      insert(:course, title: "Test Course 2")
      insert(:course, title: "Test Course 3")
      insert(:course, title: "Test Course 4")

      results = Courses.search_courses_by_title(admin, "Test", 2)

      assert length(results) == 2
    end

    test "excludes soft-deleted courses", %{admin: admin} do
      active_course = insert(:course, title: "Phoenix LiveView")

      _deleted_course =
        insert(:course, title: "Phoenix Fundamentals", deleted_at: DateTime.utc_now(:second))

      results = Courses.search_courses_by_title(admin, "Phoenix")

      assert length(results) == 1
      assert hd(results).id == active_course.id
    end

    test "returns an empty list if no courses match", %{admin: admin} do
      insert(:course, title: "React Basics")

      results = Courses.search_courses_by_title(admin, "Vue")

      assert results == []
    end

    test "respects own_only policy when searching", %{
      instructor: instructor,
      other_instructor: other
    } do
      insert(:course, title: "Elixir by me", owner_id: instructor.id)
      insert(:course, title: "Elixir by other", owner_id: other.id)

      results = Courses.search_courses_by_title(instructor, "Elixir")

      assert length(results) == 1
      assert hd(results).title == "Elixir by me"
    end
  end
end
