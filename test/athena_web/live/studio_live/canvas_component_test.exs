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
      assert html =~ "Quiz Exam"
      assert html =~ "Quiz Question"
      assert html =~ "Image"
      assert html =~ "Video"
      assert html =~ "Files &amp; Materials"
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

    test "renders attachment block with tiptap and add button" do
      attachment_block = %Block{
        id: "block-att-1",
        type: :attachment,
        content: %{"description" => %{}, "files" => []}
      }

      html =
        render_component(CanvasComponent,
          active_section_id: "sec-1",
          blocks: [attachment_block],
          active_block_id: nil
        )

      assert html =~ ~s(id="tiptap-block-att-1")
      assert html =~ ~s(phx-hook="TiptapEditor")
      assert html =~ "Add Files"
      assert html =~ "request_media_upload"
      assert html =~ ~s(phx-value-media_type="attachment")
    end

    test "renders attachment block with listed files and sizes" do
      attachment_block = %Block{
        id: "block-att-2",
        type: :attachment,
        content: %{
          "description" => %{"text" => "Download these"},
          "files" => [
            %{
              "name" => "homework.pdf",
              "size" => 2_097_152,
              "url" => "/media/hw.pdf",
              "mime" => "application/pdf"
            },
            %{
              "name" => "notes.txt",
              "size" => 1500,
              "url" => "/media/notes.txt",
              "mime" => "text/plain"
            }
          ]
        }
      }

      html =
        render_component(CanvasComponent,
          active_section_id: "sec-1",
          blocks: [attachment_block],
          active_block_id: nil
        )

      assert html =~ "homework.pdf"
      assert html =~ "notes.txt"
      assert html =~ "2.0 MB"
      assert html =~ "1.5 KB"
      assert html =~ "delete_attachment"
      assert html =~ ~s(phx-value-url="/media/hw.pdf")
    end

    test "renders exact_match quiz block with text input", %{conn: _conn} do
      quiz_block = %Block{
        id: "block-quiz-exact",
        type: :quiz_question,
        content: %{
          "question_type" => "exact_match",
          "correct_answer" => "flag{h4ck3d}",
          "body" => %{"text" => "What is the flag?"}
        }
      }

      html =
        render_component(CanvasComponent,
          active_section_id: "sec-1",
          blocks: [quiz_block],
          active_block_id: nil
        )

      assert html =~ ~s(id="tiptap-block-quiz-exact")
      assert html =~ "Correct Answer (Flag)"
      assert html =~ ~s(name="correct_answer")
      assert html =~ "flag{h4ck3d}"
    end

    test "renders single/multiple choice quiz blocks with options", %{conn: _conn} do
      quiz_block = %Block{
        id: "block-quiz-multi",
        type: :quiz_question,
        content: %{
          "question_type" => "multiple",
          "body" => %{},
          "options" => [
            %{
              "id" => "opt1",
              "text" => "Option A",
              "is_correct" => true,
              "explanation" => "Expl 1"
            },
            %{"id" => "opt2", "text" => "Option B", "is_correct" => false, "explanation" => ""}
          ]
        }
      }

      html =
        render_component(CanvasComponent,
          active_section_id: "sec-1",
          blocks: [quiz_block],
          active_block_id: nil
        )

      assert html =~ "Option A"
      assert html =~ "Expl 1"
      assert html =~ "Option B"
      assert html =~ ~s(type="checkbox")
      assert html =~ ~s(name="options[0][is_correct]")
      assert html =~ "Add Option"
      assert html =~ "remove_quiz_option"
    end

    test "renders open quiz block with text area placeholder", %{conn: _conn} do
      quiz_block = %Block{
        id: "block-quiz-open",
        type: :quiz_question,
        content: %{
          "question_type" => "open",
          "body" => %{}
        }
      }

      html =
        render_component(CanvasComponent,
          active_section_id: "sec-1",
          blocks: [quiz_block],
          active_block_id: nil
        )

      assert html =~ "Student will see a text area to write their open answer."
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

  test "renders quiz_exam block with preview card and badges", %{conn: _conn} do
    exam_block = %Block{
      id: "block-exam-1",
      type: :quiz_exam,
      content: %{
        "count" => 25,
        "time_limit" => 60
      }
    }

    html =
      render_component(CanvasComponent,
        active_section_id: "sec-1",
        blocks: [exam_block],
        active_block_id: nil
      )

    assert html =~ "Quiz Exam Generator"
    assert html =~ "25"
    assert html =~ "Questions"
    assert html =~ "60"
    assert html =~ "min"
    assert html =~ "hero-clock"
  end
end
