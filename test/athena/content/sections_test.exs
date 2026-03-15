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
      %{course: insert(:course), owner_id: Ecto.UUID.generate()}
    end

    test "should create root section with atom keys", %{course: c, owner_id: o} do
      attrs = %{title: "Root Atom", course_id: c.id, owner_id: o, order: 10}

      assert {:ok, %Section{} = section} = Sections.create_section(attrs)
      assert section.title == "Root Atom"
      assert section.order == 10

      expected_path = Section.uuid_to_ltree(section.id)
      assert Enum.join(section.path.labels, ".") == expected_path
    end

    test "should create root section with string keys", %{course: c, owner_id: o} do
      attrs = %{"title" => "Root String", "course_id" => c.id, "owner_id" => o}

      assert {:ok, %Section{} = section} = Sections.create_section(attrs)
      assert section.title == "Root String"
      assert section.id != nil
    end

    test "should create child section and save path correctly", %{course: c, owner_id: o} do
      {:ok, parent} = Sections.create_section(%{title: "Parent", course_id: c.id, owner_id: o})

      attrs = %{title: "Child", course_id: c.id, parent_id: parent.id, owner_id: o}
      assert {:ok, %Section{} = child} = Sections.create_section(attrs)

      expected_path = "#{Section.uuid_to_ltree(parent.id)}.#{Section.uuid_to_ltree(child.id)}"
      assert Enum.join(child.path.labels, ".") == expected_path
      assert child.parent_id == parent.id
    end

    test "should create deep nestings", %{course: c, owner_id: o} do
      {:ok, p} = Sections.create_section(%{title: "P", course_id: c.id, owner_id: o})

      {:ok, c1} =
        Sections.create_section(%{title: "C", course_id: c.id, parent_id: p.id, owner_id: o})

      attrs = %{title: "Grandchild", course_id: c.id, parent_id: c1.id, owner_id: o}
      assert {:ok, grandchild} = Sections.create_section(attrs)

      path = Enum.join(grandchild.path.labels, ".")
      assert String.starts_with?(path, Section.uuid_to_ltree(p.id))
      assert String.contains?(path, Section.uuid_to_ltree(c1.id))
      assert String.ends_with?(path, Section.uuid_to_ltree(grandchild.id))
    end

    test "should create section with custom ID", %{course: c, owner_id: o} do
      my_id = Ecto.UUID.generate()
      attrs = %{id: my_id, title: "Custom ID", course_id: c.id, owner_id: o}

      assert {:ok, section} = Sections.create_section(attrs)
      assert section.id == my_id
      assert Enum.join(section.path.labels, ".") == Section.uuid_to_ltree(my_id)
    end

    test "should not create section without required params", %{course: c} do
      assert {:error, changeset} = Sections.create_section(%{course_id: c.id})
      assert "can't be blank" in errors_on(changeset).title
      assert "can't be blank" in errors_on(changeset).owner_id
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
      %{course: insert(:course), owner_id: Ecto.UUID.generate()}
    end

    test "should build correct tree", %{course: c, owner_id: o} do
      {:ok, m1} = Sections.create_section(%{title: "M1", course_id: c.id, owner_id: o, order: 1})
      {:ok, m2} = Sections.create_section(%{title: "M2", course_id: c.id, owner_id: o, order: 2})

      {:ok, l1} =
        Sections.create_section(%{title: "L1", course_id: c.id, parent_id: m1.id, owner_id: o})

      {:ok, sub} =
        Sections.create_section(%{title: "Sub", course_id: c.id, parent_id: l1.id, owner_id: o})

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

    test "should keep sort order", %{course: c, owner_id: o} do
      {:ok, s2} =
        Sections.create_section(%{title: "Second", course_id: c.id, owner_id: o, order: 20})

      {:ok, s1} =
        Sections.create_section(%{title: "First", course_id: c.id, owner_id: o, order: 10})

      tree = Sections.get_course_tree(c.id)

      assert [root1, root2] = tree
      assert root1.id == s1.id
      assert root2.id == s2.id
    end

    test "should sort by creation date if order is the same", %{course: c, owner_id: o} do
      {:ok, s1} =
        Sections.create_section(%{title: "First", course_id: c.id, owner_id: o, order: 1})

      {:ok, s2} =
        Sections.create_section(%{title: "Second", course_id: c.id, owner_id: o, order: 1})

      tree = Sections.get_course_tree(c.id)

      assert [root1, root2] = tree
      assert root1.id == s1.id
      assert root2.id == s2.id
    end

    test "should return empty list when no section exists" do
      course = insert(:course)
      assert Sections.get_course_tree(course.id) == []
    end
  end
end
