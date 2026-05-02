defmodule Athena.Content.SectionsTest do
  use Athena.DataCase, async: true

  alias Athena.Content.Sections
  alias Athena.Content.Section
  import Athena.Factory

  setup do
    admin_role = insert(:role, permissions: ["admin", "courses.update"])
    admin = insert(:account, role: admin_role)

    instructor_role =
      insert(:role,
        permissions: ["courses.update"],
        policies: %{"courses.update" => ["own_only"]}
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

  describe "get_section/1 (Without ACL - Internal/Student)" do
    test "should return section by its ID" do
      section = insert(:section)
      assert {:ok, fetched} = Sections.get_section(section.id)
      assert fetched.id == section.id
    end

    test "should return error if no section found" do
      assert {:error, :not_found} = Sections.get_section(Ecto.UUID.generate())
    end
  end

  describe "get_section/2 (With ACL - Studio)" do
    test "returns section if instructor owns the parent course", %{instructor: instructor} do
      course = insert(:course, owner_id: instructor.id)
      section = insert(:section, course: course)

      assert {:ok, fetched} = Sections.get_section(instructor, section.id)
      assert fetched.id == section.id
    end

    test "returns not_found if instructor does not own the parent course", %{
      instructor: instructor,
      other_instructor: other_instructor
    } do
      course = insert(:course, owner_id: other_instructor.id)
      section = insert(:section, course: course)

      assert {:error, :not_found} = Sections.get_section(instructor, section.id)
    end
  end

  describe "create_section/2" do
    test "should create root section with string keys", %{admin: admin} do
      course = insert(:course, owner_id: admin.id)
      attrs = %{"title" => "Root String", "course_id" => course.id, "order" => 10}

      assert {:ok, %Section{} = section} = Sections.create_section(admin, attrs)
      assert section.title == "Root String"
      assert section.order == 10

      expected_path = Section.uuid_to_ltree(section.id)
      assert Enum.join(section.path.labels, ".") == expected_path
    end

    test "should create child section and save path correctly", %{admin: admin} do
      course = insert(:course, owner_id: admin.id)

      {:ok, parent} =
        Sections.create_section(admin, %{"title" => "Parent", "course_id" => course.id})

      attrs = %{
        "title" => "Child",
        "course_id" => course.id,
        "parent_id" => parent.id
      }

      assert {:ok, %Section{} = child} = Sections.create_section(admin, attrs)

      expected_path = "#{Section.uuid_to_ltree(parent.id)}.#{Section.uuid_to_ltree(child.id)}"
      assert Enum.join(child.path.labels, ".") == expected_path
      assert child.parent_id == parent.id
    end

    test "should create deep nestings", %{admin: admin} do
      course = insert(:course, owner_id: admin.id)

      {:ok, p} = Sections.create_section(admin, %{"title" => "P", "course_id" => course.id})

      {:ok, c1} =
        Sections.create_section(admin, %{
          "title" => "C",
          "course_id" => course.id,
          "parent_id" => p.id
        })

      attrs = %{
        "title" => "Grandchild",
        "course_id" => course.id,
        "parent_id" => c1.id
      }

      assert {:ok, grandchild} = Sections.create_section(admin, attrs)

      path = Enum.join(grandchild.path.labels, ".")
      assert String.starts_with?(path, Section.uuid_to_ltree(p.id))
      assert String.contains?(path, Section.uuid_to_ltree(c1.id))
      assert String.ends_with?(path, Section.uuid_to_ltree(grandchild.id))
    end

    test "should create section with custom ID", %{admin: admin} do
      course = insert(:course, owner_id: admin.id)
      my_id = Ecto.UUID.generate()
      attrs = %{"id" => my_id, "title" => "Custom ID", "course_id" => course.id}

      assert {:ok, section} = Sections.create_section(admin, attrs)
      assert section.id == my_id
      assert Enum.join(section.path.labels, ".") == Section.uuid_to_ltree(my_id)
    end

    test "should not create section without required params", %{admin: admin} do
      course = insert(:course, owner_id: admin.id)
      assert {:error, changeset} = Sections.create_section(admin, %{"course_id" => course.id})
      assert "can't be blank" in errors_on(changeset).title
    end

    test "returns unauthorized if instructor tries to add section to someone else's course", %{
      instructor: instructor,
      other_instructor: other
    } do
      course = insert(:course, owner_id: other.id)
      attrs = %{"title" => "Hacked", "course_id" => course.id}

      assert {:error, :unauthorized} = Sections.create_section(instructor, attrs)
    end
  end

  describe "update_section/3" do
    test "should update section", %{admin: admin} do
      course = insert(:course, owner_id: admin.id)
      section = insert(:section, title: "Old", course: course)

      assert {:ok, updated} =
               Sections.update_section(admin, section, %{"title" => "New", "order" => 99})

      assert updated.title == "New"
      assert updated.order == 99
    end

    test "should return error changeset with invalid fields", %{admin: admin} do
      course = insert(:course, owner_id: admin.id)
      section = insert(:section, course: course)
      assert {:error, changeset} = Sections.update_section(admin, section, %{"title" => ""})
      assert "can't be blank" in errors_on(changeset).title
    end

    test "should update ltree path of section and its descendants when parent_id changes", %{
      admin: admin
    } do
      course = insert(:course, owner_id: admin.id)

      {:ok, root1} =
        Sections.create_section(admin, %{
          "title" => "Root1",
          "course_id" => course.id
        })

      {:ok, root2} =
        Sections.create_section(admin, %{
          "title" => "Root2",
          "course_id" => course.id
        })

      {:ok, child} =
        Sections.create_section(admin, %{
          "title" => "Child",
          "course_id" => course.id,
          "parent_id" => root1.id
        })

      {:ok, grandchild} =
        Sections.create_section(admin, %{
          "title" => "Grandchild",
          "course_id" => course.id,
          "parent_id" => child.id
        })

      assert {:ok, updated_child} =
               Sections.update_section(admin, child, %{"parent_id" => root2.id})

      expected_child_path =
        "#{Section.uuid_to_ltree(root2.id)}.#{Section.uuid_to_ltree(child.id)}"

      assert Enum.join(updated_child.path.labels, ".") == expected_child_path

      {:ok, updated_grandchild} = Sections.get_section(grandchild.id)
      expected_grandchild_path = "#{expected_child_path}.#{Section.uuid_to_ltree(grandchild.id)}"
      assert Enum.join(updated_grandchild.path.labels, ".") == expected_grandchild_path
    end

    test "returns unauthorized if user lacks edit rights on course", %{
      instructor: instructor,
      other_instructor: other
    } do
      course = insert(:course, owner_id: other.id)
      section = insert(:section, course: course)

      assert {:error, :unauthorized} =
               Sections.update_section(instructor, section, %{"title" => "Hacked"})
    end
  end

  describe "delete_section/2" do
    test "should remove section", %{admin: admin} do
      course = insert(:course, owner_id: admin.id)
      section = insert(:section, course: course)
      assert {:ok, _} = Sections.delete_section(admin, section)
      assert Repo.get(Section, section.id) == nil
    end

    test "returns unauthorized if user lacks edit rights on course", %{
      instructor: instructor,
      other_instructor: other
    } do
      course = insert(:course, owner_id: other.id)
      section = insert(:section, course: course)

      assert {:error, :unauthorized} = Sections.delete_section(instructor, section)
    end
  end

  describe "reorder_section/3" do
    test "should reorder siblings and update their order fields", %{admin: admin} do
      course = insert(:course, owner_id: admin.id)

      {:ok, s1} =
        Sections.create_section(admin, %{"title" => "S1", "course_id" => course.id, "order" => 0})

      {:ok, s2} =
        Sections.create_section(admin, %{"title" => "S2", "course_id" => course.id, "order" => 1})

      {:ok, s3} =
        Sections.create_section(admin, %{"title" => "S3", "course_id" => course.id, "order" => 2})

      assert {:ok, updated_s3} = Sections.reorder_section(admin, s3, 0)
      assert updated_s3.order == 0

      {:ok, new_s1} = Sections.get_section(s1.id)
      {:ok, new_s2} = Sections.get_section(s2.id)

      assert new_s1.order == 1
      assert new_s2.order == 2
    end

    test "returns unauthorized if user lacks edit rights on course", %{
      instructor: instructor,
      other_instructor: other
    } do
      course = insert(:course, owner_id: other.id)
      section = insert(:section, course: course)

      assert {:error, :unauthorized} = Sections.reorder_section(instructor, section, 0)
    end
  end

  describe "get_course_tree/2" do
    test "should build correct tree", %{admin: admin} do
      course = insert(:course, owner_id: admin.id)

      {:ok, m1} =
        Sections.create_section(admin, %{"title" => "M1", "course_id" => course.id, "order" => 1})

      {:ok, m2} =
        Sections.create_section(admin, %{"title" => "M2", "course_id" => course.id, "order" => 2})

      {:ok, l1} =
        Sections.create_section(admin, %{
          "title" => "L1",
          "course_id" => course.id,
          "parent_id" => m1.id
        })

      {:ok, sub} =
        Sections.create_section(admin, %{
          "title" => "Sub",
          "course_id" => course.id,
          "parent_id" => l1.id
        })

      tree = Sections.get_course_tree(course.id)

      assert length(tree) == 2
      [tree_m1, tree_m2] = tree

      assert tree_m1.id == m1.id
      assert tree_m2.id == m2.id

      assert length(tree_m1.children) == 1
      child_l1 = hd(tree_m1.children)
      assert child_l1.id == l1.id
      assert length(child_l1.children) == 1
      assert hd(child_l1.children).id == sub.id
    end

    test "should keep sort order", %{admin: admin} do
      course = insert(:course, owner_id: admin.id)

      {:ok, s2} =
        Sections.create_section(admin, %{
          "title" => "Second",
          "course_id" => course.id,
          "order" => 20
        })

      {:ok, s1} =
        Sections.create_section(admin, %{
          "title" => "First",
          "course_id" => course.id,
          "order" => 10
        })

      tree = Sections.get_course_tree(course.id)

      assert [root1, root2] = tree
      assert root1.id == s1.id
      assert root2.id == s2.id
    end

    test "should filter tree based on user policies", %{admin: admin, student: student} do
      course = insert(:course, owner_id: admin.id)

      {:ok, s_public} =
        Sections.create_section(admin, %{
          "title" => "Public",
          "course_id" => course.id,
          "visibility" => :enrolled
        })

      {:ok, _s_hidden} =
        Sections.create_section(admin, %{
          "title" => "Hidden",
          "course_id" => course.id,
          "visibility" => :hidden
        })

      assert length(Sections.get_course_tree(course.id, :all)) == 2
      assert length(Sections.get_course_tree(course.id, admin)) == 1

      tree = Sections.get_course_tree(course.id, student)
      assert length(tree) == 1
      assert hd(tree).id == s_public.id
    end
  end

  describe "list_linear_lessons/2" do
    test "returns flat list of sections, skipping those without blocks", %{admin: admin} do
      course = insert(:course, owner_id: admin.id)

      {:ok, root1} =
        Sections.create_section(admin, %{"title" => "R1", "course_id" => course.id, "order" => 1})

      {:ok, child1} =
        Sections.create_section(admin, %{
          "title" => "C1",
          "course_id" => course.id,
          "parent_id" => root1.id,
          "order" => 1
        })

      {:ok, root2} =
        Sections.create_section(admin, %{"title" => "R2", "course_id" => course.id, "order" => 2})

      {:ok, _child2} =
        Sections.create_section(admin, %{
          "title" => "C2",
          "course_id" => course.id,
          "parent_id" => root2.id,
          "order" => 1
        })

      insert(:block, section: nil, section_id: child1.id)
      insert(:block, section: nil, section_id: root2.id)

      lessons = Sections.list_linear_lessons(course.id)
      assert length(lessons) == 2
      assert Enum.map(lessons, & &1.id) == [child1.id, root2.id]
    end

    test "returns empty list if no sections have blocks", %{admin: admin} do
      course = insert(:course, owner_id: admin.id)

      {:ok, root1} = Sections.create_section(admin, %{"title" => "R1", "course_id" => course.id})

      {:ok, _child1} =
        Sections.create_section(admin, %{
          "title" => "C1",
          "course_id" => course.id,
          "parent_id" => root1.id
        })

      assert Sections.list_linear_lessons(course.id) == []
    end
  end
end
