defmodule AthenaWeb.StudioLive.Builder.StructureSidebarComponentTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias AthenaWeb.StudioLive.Builder.StructureSidebarComponent
  alias Athena.Content.Section
  alias EctoLtree.LabelTree

  defp mock_section(id, title, labels, children \\ []) do
    %Section{
      id: id,
      title: title,
      path: %LabelTree{labels: labels},
      children: children
    }
  end

  describe "Root Level" do
    test "renders empty state message when no sections exist" do
      html =
        render_component(StructureSidebarComponent,
          sections: [],
          viewing_parent_id: nil,
          active_section_id: nil,
          role: :owner
        )

      assert html =~ "No sections yet. Create your first one!"
      assert html =~ "Add Section"
      assert html =~ ~s(phx-value-parent_id="")
    end

    test "renders root sections and highlights active section" do
      s1 = mock_section("uuid-1", "Intro to Elixir", ["uuid_1"])
      s2 = mock_section("uuid-2", "Advanced OTP", ["uuid_2"])

      html =
        render_component(StructureSidebarComponent,
          sections: [s1, s2],
          viewing_parent_id: nil,
          active_section_id: "uuid-1",
          role: :owner
        )

      assert html =~ "Intro to Elixir"
      assert html =~ "Advanced OTP"

      assert html =~ ~r/id="section-uuid-1"[^>]*bg-primary\/10 text-primary font-bold/
      assert html =~ ~r/id="section-uuid-2"[^>]*hover:bg-base-200/
    end
  end

  describe "Drill-down (Nested Levels)" do
    test "renders children and chevrons when viewing a parent" do
      grandchild = mock_section("uuid-gc", "Grandchild", ["uuid_p", "uuid_c", "uuid_gc"])

      child =
        mock_section("uuid-child", "Child Lesson", ["uuid_parent", "uuid_child"], [grandchild])

      parent = mock_section("uuid-parent", "Parent Folder", ["uuid_parent"], [child])

      html =
        render_component(StructureSidebarComponent,
          sections: [parent],
          viewing_parent_id: "uuid-parent",
          active_section_id: nil,
          role: :owner
        )

      assert html =~ "Child Lesson"
      refute html =~ ~r/id="section-uuid-parent"/

      assert html =~ "hero-chevron-right"
      assert html =~ ~s(title="Drill down")
      assert html =~ "Up"
      assert html =~ ~s(phx-value-id="uuid-parent")
      assert html =~ "Add Section"
      assert html =~ ~s(phx-value-parent_id="uuid-parent")
    end

    test "renders specific empty message when viewing an empty parent folder" do
      parent = mock_section("uuid-empty", "Empty Folder", ["uuid_empty"], [])

      html =
        render_component(StructureSidebarComponent,
          sections: [parent],
          viewing_parent_id: "uuid-empty",
          active_section_id: nil,
          role: :owner
        )

      assert html =~ "This folder is empty."
      assert html =~ "Add Section"
    end
  end

  describe "Role-based Rendering" do
    test "renders Add button and Sortable hook for writer/owner" do
      section = mock_section("uuid-1", "Intro", ["uuid_1"])

      html =
        render_component(StructureSidebarComponent,
          sections: [section],
          viewing_parent_id: nil,
          active_section_id: nil,
          role: :writer
        )

      assert html =~ "Add Section"
      assert html =~ ~s(phx-hook="Sortable")
      assert html =~ "Add section here"
    end

    test "hides Add button and Sortable hook for reader" do
      section = mock_section("uuid-1", "Intro", ["uuid_1"])

      html =
        render_component(StructureSidebarComponent,
          sections: [section],
          viewing_parent_id: nil,
          active_section_id: nil,
          role: :reader
        )

      refute html =~ "Add Section"
      refute html =~ ~s(phx-hook="Sortable")
      refute html =~ "Add section here"
    end
  end

  describe "New UI Features" do
    test "renders course map button in footer" do
      html =
        render_component(StructureSidebarComponent,
          sections: [],
          viewing_parent_id: nil,
          active_section_id: nil,
          role: :owner
        )

      assert html =~ "open_quick_nav"
      assert html =~ "hero-map"
      assert html =~ "Open Course Map"
    end

    test "hides 'Up' button at root level" do
      html =
        render_component(StructureSidebarComponent,
          sections: [],
          viewing_parent_id: nil,
          active_section_id: nil,
          role: :owner
        )

      refute html =~ "phx-click=\"drill_up\""
    end

    test "shows 'Up' button when inside a folder" do
      parent = mock_section("uuid-p", "Parent", ["uuid_p"])

      html =
        render_component(StructureSidebarComponent,
          sections: [parent],
          viewing_parent_id: "uuid-p",
          active_section_id: nil,
          role: :owner
        )

      assert html =~ "phx-click=\"drill_up\""
      assert html =~ "Up"
    end
  end
end
