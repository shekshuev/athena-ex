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
      assert html =~ "Image"
      assert html =~ "Video"
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

    test "renders image block placeholder when no url is set" do
      image_block = %Block{id: "block-img-1", type: :image, content: %{"url" => nil}}

      html =
        render_component(CanvasComponent,
          active_section_id: "sec-1",
          blocks: [image_block],
          active_block_id: nil
        )

      assert html =~ "Click to upload image"
      assert html =~ "request_media_upload"
      assert html =~ ~s(phx-value-media_type="image")
    end

    test "renders image tag when url is present" do
      image_block = %Block{
        id: "block-img-2",
        type: :image,
        content: %{"url" => "http://s3.com/pic.jpg", "alt" => "Cool pic"}
      }

      html =
        render_component(CanvasComponent,
          active_section_id: "sec-1",
          blocks: [image_block],
          active_block_id: nil
        )

      assert html =~ "<img"
      assert html =~ ~s(src="http://s3.com/pic.jpg")
      assert html =~ ~s(alt="Cool pic")
      refute html =~ "Click to upload image"
    end

    test "renders video block placeholder when no url is set" do
      video_block = %Block{id: "block-vid-1", type: :video, content: %{"url" => nil}}

      html =
        render_component(CanvasComponent,
          active_section_id: "sec-1",
          blocks: [video_block],
          active_block_id: nil
        )

      assert html =~ "Click to upload video"
      assert html =~ "request_media_upload"
      assert html =~ ~s(phx-value-media_type="video")
    end

    test "renders video tag when url is present" do
      video_block = %Block{
        id: "block-vid-2",
        type: :video,
        content: %{
          "url" => "http://s3.com/vid.mp4",
          "poster_url" => "http://s3.com/poster.jpg",
          "controls" => true
        }
      }

      html =
        render_component(CanvasComponent,
          active_section_id: "sec-1",
          blocks: [video_block],
          active_block_id: nil
        )

      assert html =~ "<video"
      assert html =~ ~s(src="http://s3.com/vid.mp4")
      assert html =~ ~s(poster="http://s3.com/poster.jpg")
      assert html =~ "controls"
      refute html =~ "Click to upload video"
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
