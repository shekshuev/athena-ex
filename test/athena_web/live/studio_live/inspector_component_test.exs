defmodule AthenaWeb.StudioLive.Builder.InspectorComponentTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory
  alias AthenaWeb.StudioLive.Builder.InspectorComponent
  alias Athena.Content.AccessRules

  describe "Empty State" do
    test "prompts user to select an item when nothing is active" do
      html =
        render_component(InspectorComponent,
          id: "inspector",
          active_section: nil,
          active_block: nil
        )

      assert html =~ "Select a section or block to edit settings"
    end
  end

  describe "Section Inspector" do
    setup do
      %{section: build(:section, title: "Introduction to Elixir")}
    end

    test "renders basic section fields", %{section: section} do
      html =
        render_component(InspectorComponent,
          id: "inspector",
          active_section: section,
          active_block: nil
        )

      assert html =~ "Section"
      assert html =~ section.title
      assert html =~ "Section Title"
      assert html =~ "Who can see this section?"
      assert html =~ ~s(name="section[title]")
      assert html =~ ~s(id="section-inspector-form-#{section.id}")

      assert html =~ "Move To..."
      assert html =~ "Delete Section"
    end

    test "shows access rules inputs when visibility is restricted", %{section: base_section} do
      section = %{base_section | visibility: :restricted, access_rules: %AccessRules{}}

      html =
        render_component(InspectorComponent,
          id: "inspector",
          active_section: section,
          active_block: nil
        )

      assert html =~ "Unlock At (Optional)"
      assert html =~ "Lock At (Optional)"
      assert html =~ ~s(name="section[access_rules][unlock_at]")
      assert html =~ ~s(name="section[access_rules][lock_at]")
    end

    test "hides access rules inputs when visibility is public", %{section: base_section} do
      section = %{base_section | visibility: :public}

      html =
        render_component(InspectorComponent,
          id: "inspector",
          active_section: section,
          active_block: nil
        )

      refute html =~ "Unlock At (Optional)"
      refute html =~ "Lock At (Optional)"
    end
  end

  describe "Block Inspector" do
    setup do
      %{block: build(:block, type: :text)}
    end

    test "renders text block fields", %{block: block} do
      html =
        render_component(InspectorComponent,
          id: "inspector",
          active_section: nil,
          active_block: block
        )

      assert html =~ "text Block"
      assert html =~ "Who can see this block?"
      assert html =~ ~s(id="block-inspector-form-#{block.id}")

      refute html =~ "Execution Settings"
      refute html =~ "Programming Language"

      assert html =~ "Save to Library"
      assert html =~ "Delete Block"
    end

    test "renders code block execution settings", %{block: base_block} do
      block = %{
        base_block
        | type: :code,
          content: %{"language" => "elixir", "execution_mode" => "run"}
      }

      html =
        render_component(InspectorComponent,
          id: "inspector",
          active_section: nil,
          active_block: block
        )

      assert html =~ "code Block"
      assert html =~ "Execution Settings"
      assert html =~ "Programming Language"
      assert html =~ "Execution Mode"

      assert html =~ ~s(name="block[content][language]")
      assert html =~ ~s(name="block[content][execution_mode]")
    end

    test "shows access rules inputs when block visibility is restricted", %{block: base_block} do
      block = %{base_block | visibility: :restricted, access_rules: %AccessRules{}}

      html =
        render_component(InspectorComponent,
          id: "inspector",
          active_section: nil,
          active_block: block
        )

      assert html =~ "Unlock At (Optional)"
      assert html =~ ~s(name="block[access_rules][unlock_at]")
    end
  end
end
