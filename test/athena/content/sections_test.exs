defmodule Athena.Content.SectionsTest do
  use Athena.DataCase, async: true

  alias Athena.Content.Sections
  alias Athena.Content.Section
  import Athena.Factory

  describe "get_section/1" do
    test "should return section by its ID" do
      section = insert(:section)
      assert {:ok, fetched} = Sections.get_section(section.id)
      assert fetched.id == section.id
    end

    test "should return error if no section found" do
      assert {:error, :not_found} = Sections.get_section(Ecto.UUID.generate())
    end
  end

  describe "create_section/1" do
    setup do
      %{course: insert(:course)}
    end

    test "should create root section with atom keys", %{course: c} do
      attrs = %{"title" => "Root Atom", "course_id" => c.id, "order" => 10}

      assert {:ok, %Section{} = section} = Sections.create_section(attrs)
      assert section.title == "Root Atom"
      assert section.order == 10

      expected_path = Section.uuid_to_ltree(section.id)
      assert Enum.join(section.path.labels, ".") == expected_path
    end

    test "should create root section with string keys", %{course: c} do
      attrs = %{"title" => "Root String", "course_id" => c.id}

      assert {:ok, %Section{} = section} = Sections.create_section(attrs)
      assert section.title == "Root String"
      assert section.id != nil
    end

    test "should create child section and save path correctly", %{course: c} do
      {:ok, parent} =
        Sections.create_section(%{"title" => "Parent", "course_id" => c.id})

      attrs = %{
        "title" => "Child",
        "course_id" => c.id,
        "parent_id" => parent.id
      }

      assert {:ok, %Section{} = child} = Sections.create_section(attrs)

      expected_path = "#{Section.uuid_to_ltree(parent.id)}.#{Section.uuid_to_ltree(child.id)}"
      assert Enum.join(child.path.labels, ".") == expected_path
      assert child.parent_id == parent.id
    end

    test "should create deep nestings", %{course: c} do
      {:ok, p} = Sections.create_section(%{"title" => "P", "course_id" => c.id})

      {:ok, c1} =
        Sections.create_section(%{
          "title" => "C",
          "course_id" => c.id,
          "parent_id" => p.id
        })

      attrs = %{
        "title" => "Grandchild",
        "course_id" => c.id,
        "parent_id" => c1.id
      }

      assert {:ok, grandchild} = Sections.create_section(attrs)

      path = Enum.join(grandchild.path.labels, ".")
      assert String.starts_with?(path, Section.uuid_to_ltree(p.id))
      assert String.contains?(path, Section.uuid_to_ltree(c1.id))
      assert String.ends_with?(path, Section.uuid_to_ltree(grandchild.id))
    end

    test "should create section with custom ID", %{course: c} do
      my_id = Ecto.UUID.generate()
      attrs = %{"id" => my_id, "title" => "Custom ID", "course_id" => c.id}

      assert {:ok, section} = Sections.create_section(attrs)
      assert section.id == my_id
      assert Enum.join(section.path.labels, ".") == Section.uuid_to_ltree(my_id)
    end

    test "should not create section without required params", %{course: c} do
      assert {:error, changeset} = Sections.create_section(%{"course_id" => c.id})
      assert "can't be blank" in errors_on(changeset).title
    end
  end

  describe "update_section/2" do
    test "should update section" do
      section = insert(:section, title: "Old")
      assert {:ok, updated} = Sections.update_section(section, %{title: "New", order: 99})
      assert updated.title == "New"
      assert updated.order == 99
    end

    test "should return error changeset with invalid fields" do
      section = insert(:section)
      assert {:error, changeset} = Sections.update_section(section, %{title: ""})
      assert "can't be blank" in errors_on(changeset).title
    end

    test "should update ltree path of section and its descendants when parent_id changes" do
      course = insert(:course)

      {:ok, root1} =
        Sections.create_section(%{
          "title" => "Root1",
          "course_id" => course.id
        })

      {:ok, root2} =
        Sections.create_section(%{
          "title" => "Root2",
          "course_id" => course.id
        })

      {:ok, child} =
        Sections.create_section(%{
          "title" => "Child",
          "course_id" => course.id,
          "parent_id" => root1.id
        })

      {:ok, grandchild} =
        Sections.create_section(%{
          "title" => "Grandchild",
          "course_id" => course.id,
          "parent_id" => child.id
        })

      assert {:ok, updated_child} = Sections.update_section(child, %{"parent_id" => root2.id})

      expected_child_path =
        "#{Section.uuid_to_ltree(root2.id)}.#{Section.uuid_to_ltree(child.id)}"

      assert Enum.join(updated_child.path.labels, ".") == expected_child_path

      {:ok, updated_grandchild} = Sections.get_section(grandchild.id)
      expected_grandchild_path = "#{expected_child_path}.#{Section.uuid_to_ltree(grandchild.id)}"
      assert Enum.join(updated_grandchild.path.labels, ".") == expected_grandchild_path
    end
  end

  describe "delete_section/1" do
    test "should remove section" do
      section = insert(:section)
      assert {:ok, _} = Sections.delete_section(section)
      assert Repo.get(Section, section.id) == nil
    end
  end

  describe "get_course_tree/1" do
    setup do
      %{course: insert(:course)}
    end

    test "should build correct tree", %{course: c} do
      {:ok, m1} =
        Sections.create_section(%{
          "title" => "M1",
          "course_id" => c.id,
          "order" => 1
        })

      {:ok, m2} =
        Sections.create_section(%{
          "title" => "M2",
          "course_id" => c.id,
          "order" => 2
        })

      {:ok, l1} =
        Sections.create_section(%{
          "title" => "L1",
          "course_id" => c.id,
          "parent_id" => m1.id
        })

      {:ok, sub} =
        Sections.create_section(%{
          "title" => "Sub",
          "course_id" => c.id,
          "parent_id" => l1.id
        })

      tree = Sections.get_course_tree(c.id)

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

    test "should keep sort order", %{course: c} do
      {:ok, s2} =
        Sections.create_section(%{
          "title" => "Second",
          "course_id" => c.id,
          "order" => 20
        })

      {:ok, s1} =
        Sections.create_section(%{
          "title" => "First",
          "course_id" => c.id,
          "order" => 10
        })

      tree = Sections.get_course_tree(c.id)

      assert [root1, root2] = tree
      assert root1.id == s1.id
      assert root2.id == s2.id
    end

    test "should sort by creation date if order is the same", %{course: c} do
      {:ok, s1} =
        Sections.create_section(%{
          "title" => "First",
          "course_id" => c.id,
          "order" => 1
        })

      {:ok, s2} =
        Sections.create_section(%{
          "title" => "Second",
          "course_id" => c.id,
          "order" => 1
        })

      tree = Sections.get_course_tree(c.id)

      assert [root1, root2] = tree
      assert root1.id == s1.id
      assert root2.id == s2.id
    end

    test "should return empty list when no section exists" do
      course = insert(:course)
      assert Sections.get_course_tree(course.id) == []
    end

    test "should filter tree based on user policies", %{course: c} do
      {:ok, s_public} =
        Sections.create_section(%{
          "title" => "Public",
          "course_id" => c.id,
          "visibility" => :enrolled
        })

      {:ok, _s_hidden} =
        Sections.create_section(%{
          "title" => "Hidden",
          "course_id" => c.id,
          "visibility" => :hidden
        })

      assert length(Sections.get_course_tree(c.id, :all)) == 2

      admin_role = insert(:role, permissions: ["admin"])
      admin = insert(:account, role: admin_role)
      assert length(Sections.get_course_tree(c.id, admin)) == 1

      user_role = insert(:role, permissions: [])
      user = insert(:account, role: user_role)

      tree = Sections.get_course_tree(c.id, user)
      assert length(tree) == 1
      assert hd(tree).id == s_public.id
    end
  end

  describe "reorder_section/2" do
    setup do
      %{course: insert(:course)}
    end

    test "should reorder siblings and update their order fields", %{course: c} do
      {:ok, s1} =
        Sections.create_section(%{
          "title" => "S1",
          "course_id" => c.id,
          "order" => 0
        })

      {:ok, s2} =
        Sections.create_section(%{
          "title" => "S2",
          "course_id" => c.id,
          "order" => 1
        })

      {:ok, s3} =
        Sections.create_section(%{
          "title" => "S3",
          "course_id" => c.id,
          "order" => 2
        })

      assert {:ok, updated_s3} = Sections.reorder_section(s3, 0)

      assert updated_s3.order == 0

      {:ok, new_s1} = Sections.get_section(s1.id)
      {:ok, new_s2} = Sections.get_section(s2.id)

      assert new_s1.order == 1
      assert new_s2.order == 2
    end
  end

  describe "get_section/2 (With ACL)" do
    setup do
      role =
        insert(:role,
          permissions: ["courses.update"],
          policies: %{"courses.update" => ["own_only"]}
        )

      instructor = insert(:account, role: role)
      other_instructor = insert(:account, role: role)
      %{instructor: instructor, other_instructor: other_instructor}
    end

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
end
