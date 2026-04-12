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

    test "shows floating add menu when section has no blocks" do
      html =
        render_component(CanvasComponent,
          active_section_id: "some-section-id",
          blocks: [],
          active_block_id: nil
        )

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

  describe "Visual Previews (Inactive Blocks)" do
    test "renders text blocks with TiptapEditor hook in edit mode" do
      text_block = %Block{id: "block-123", type: :text, content: %{"text" => "hello"}}

      html =
        render_component(CanvasComponent,
          active_section_id: "sec-1",
          blocks: [text_block],
          active_block_id: nil
        )

      assert html =~ ~s(id="tiptap-edit-block-123")
      assert html =~ ~s(phx-hook="TiptapEditor")
      assert html =~ ~s(data-id="block-123")
    end

    test "renders code blocks with actual code content" do
      code_block = %Block{
        id: "block-456",
        type: :code,
        content: %{"language" => "elixir", "code" => "IO.puts(:ok)"}
      }

      html =
        render_component(CanvasComponent,
          active_section_id: "sec-1",
          blocks: [code_block],
          active_block_id: nil
        )

      assert html =~ "elixir"
      assert html =~ "IO.puts(:ok)"
    end

    test "renders image block placeholder when no url is set" do
      image_block = %Block{id: "block-img-1", type: :image, content: %{"url" => nil}}

      html =
        render_component(CanvasComponent,
          active_section_id: "sec-1",
          blocks: [image_block],
          active_block_id: nil
        )

      assert html =~ "Image not uploaded yet"
      assert html =~ "hero-photo"
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
    end

    test "renders quiz_exam block preview card" do
      exam_block = %Block{
        id: "block-exam-1",
        type: :quiz_exam,
        content: %{"count" => 25, "time_limit" => 60}
      }

      html =
        render_component(CanvasComponent,
          active_section_id: "sec-1",
          blocks: [exam_block],
          active_block_id: nil
        )

      assert html =~ "Final Exam"
      assert html =~ "25 Questions"
      assert html =~ "60 Min"
    end
  end

  describe "Contextual Editors (Active Blocks)" do
    test "renders attachment manager WHEN ACTIVE" do
      attachment_block = %Block{
        id: "block-att-2",
        type: :attachment,
        content: %{
          "files" => [%{"name" => "homework.pdf", "url" => "/media/hw.pdf"}]
        }
      }

      html =
        render_component(CanvasComponent,
          active_section_id: "sec-1",
          blocks: [attachment_block],
          active_block_id: "block-att-2"
        )

      assert html =~ "Manage Files"
      assert html =~ "homework.pdf"
      assert html =~ "Upload File"
      assert html =~ "delete_attachment"
      assert html =~ ~s(phx-value-url="/media/hw.pdf")
    end

    test "renders media upload shortcut WHEN ACTIVE" do
      video_block = %Block{id: "block-vid-1", type: :video, content: %{"url" => nil}}

      html =
        render_component(CanvasComponent,
          active_section_id: "sec-1",
          blocks: [video_block],
          active_block_id: "block-vid-1"
        )

      assert html =~ "Upload Media"
      assert html =~ "request_media_upload"
      assert html =~ ~s(phx-value-media_type="video")
    end

    test "renders exact_match quiz editor WHEN ACTIVE" do
      quiz_block = %Block{
        id: "block-quiz-exact",
        type: :quiz_question,
        content: %{
          "question_type" => "exact_match",
          "correct_answer" => "flag{h4ck3d}"
        }
      }

      html =
        render_component(CanvasComponent,
          active_section_id: "sec-1",
          blocks: [quiz_block],
          active_block_id: "block-quiz-exact"
        )

      assert html =~ "Answer Editor"
      assert html =~ "Correct Answer (Flag)"
      assert html =~ ~s(name="correct_answer")
      assert html =~ "flag{h4ck3d}"
    end

    test "renders single/multiple choice quiz editor WHEN ACTIVE" do
      quiz_block = %Block{
        id: "block-quiz-multi",
        type: :quiz_question,
        content: %{
          "question_type" => "multiple",
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
          active_block_id: "block-quiz-multi"
        )

      assert html =~ "Answer Editor"
      assert html =~ "Option A"
      assert html =~ "Expl 1"
      assert html =~ "Option B"
      assert html =~ ~s(type="checkbox")
      assert html =~ ~s(name="options[0][is_correct]")
      assert html =~ "Add Option"
      assert html =~ "remove_quiz_option"
    end

    test "renders open quiz message WHEN ACTIVE" do
      quiz_block = %Block{
        id: "block-quiz-open",
        type: :quiz_question,
        content: %{"question_type" => "open"}
      }

      html =
        render_component(CanvasComponent,
          active_section_id: "sec-1",
          blocks: [quiz_block],
          active_block_id: "block-quiz-open"
        )

      assert html =~ "Answer Editor"
      assert html =~ "Student will see a text area to write their open answer."
    end
  end

  describe "Active State Highlighting" do
    test "highlights the active block with ring-2 ring-primary" do
      block1 = %Block{id: "block-1", type: :text, content: %{}}
      block2 = %Block{id: "block-2", type: :text, content: %{}}

      html =
        render_component(CanvasComponent,
          active_section_id: "sec-1",
          blocks: [block1, block2],
          active_block_id: "block-1"
        )

      assert html =~ ~r/id="block-block-1".*?ring-2 ring-primary/s
      assert html =~ ~r/id="block-block-2".*?ring-1 ring-base-300/s
    end
  end
end
