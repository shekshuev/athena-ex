defmodule AthenaWeb.StudioLive.Builder.CanvasComponentTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias AthenaWeb.StudioLive.Builder.CanvasComponent
  alias Athena.Content.Block

  describe "Empty States" do
    test "shows prompt when no section is selected" do
      html =
        render_component(CanvasComponent,
          active_section_id: nil,
          blocks: [],
          active_block_id: nil
        )

      assert html =~ "Select a section from the sidebar to view its blocks."
      refute html =~ "Add Content"
    end

    test "shows empty section message and add button when section has no blocks" do
      html =
        render_component(CanvasComponent,
          active_section_id: "some-section-id",
          blocks: [],
          active_block_id: nil
        )

      assert html =~ "This section is empty."
      assert html =~ "Add Content"
      assert html =~ "Text Block"
      assert html =~ "Code Sandbox"
    end
  end

  describe "Rendering Blocks" do
    test "renders text blocks with TiptapEditor hook" do
      text_block = %Block{id: "block-123", type: :text, content: %{"text" => "hello"}}

      html =
        render_component(CanvasComponent,
          active_section_id: "sec-1",
          blocks: [text_block],
          active_block_id: nil
        )

      assert html =~ ~s(id="tiptap-block-123")
      assert html =~ ~s(phx-hook="TiptapEditor")
      assert html =~ ~s(data-id="block-123")
    end

    test "renders code blocks with generic preview placeholder" do
      code_block = %Block{id: "block-456", type: :code, content: %{}}

      html =
        render_component(CanvasComponent,
          active_section_id: "sec-1",
          blocks: [code_block],
          active_block_id: nil
        )

      assert html =~ "Preview block content"

      assert html =~ "code"
      refute html =~ "TiptapEditor"
    end
  end

  describe "Active State" do
    test "highlights the active block" do
      block1 = %Block{id: "block-1", type: :text, content: %{}}
      block2 = %Block{id: "block-2", type: :text, content: %{}}

      html =
        render_component(CanvasComponent,
          active_section_id: "sec-1",
          blocks: [block1, block2],
          active_block_id: "block-1"
        )

      assert html =~ ~r/id="block-block-1"[^>]*ring-primary shadow-md/

      refute html =~ ~r/id="block-block-2"[^>]*ring-primary shadow-md/
      assert html =~ ~r/id="block-block-2"[^>]*ring-base-200/
    end
  end
end
