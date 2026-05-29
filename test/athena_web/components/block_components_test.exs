defmodule AthenaWeb.BlockComponentsTest do
  use AthenaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Phoenix.Component
  import AthenaWeb.BlockComponents

  import Athena.Factory

  describe "content_block/1 :text" do
    setup do
      block = insert(:block, type: :text, content: %{"text" => "Some amazing text content"})
      %{block: block}
    end

    test "renders text block in :edit mode", %{block: block} do
      assigns = %{block: block}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:edit} active={true} />
        """)

      assert html =~ "tiptap-edit-#{block.id}"
      assert html =~ "Some amazing text content"
      assert html =~ "border-primary"
      assert html =~ "border-2"
    end

    test "renders text block in :play mode", %{block: block} do
      assigns = %{block: block}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:play} />
        """)

      assert html =~ "tiptap-play-#{block.id}"
      assert html =~ "Some amazing text content"
      refute html =~ "ring-primary"
      assert html =~ "mb-10"
    end

    test "renders text block in :review mode", %{block: block} do
      assigns = %{block: block}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:review} />
        """)

      assert html =~ "tiptap-review-#{block.id}"
      assert html =~ "Some amazing text content"
      refute html =~ "ring-primary"
      assert html =~ "mb-10"
    end

    test "renders text block in :preview mode as read-only", %{block: block} do
      assigns = %{block: block}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:preview} active={false} />
        """)

      assert html =~ "tiptap-preview-#{block.id}"
      assert html =~ "Some amazing text content"
      assert html =~ ~s(data-readonly="true")
      assert html =~ "cursor-default"
      refute html =~ "ring-primary"
    end
  end

  describe "content_block/1 :image" do
    setup do
      block =
        insert(:block,
          type: :image,
          content: %{"url" => "http://test.com/img.png", "alt" => "Test Image"}
        )

      empty_block = insert(:block, type: :image, content: %{})
      %{block: block, empty_block: empty_block}
    end

    test "renders image cleanly in :play mode", %{block: block} do
      assigns = %{block: block}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:play} />
        """)

      assert html =~ "test.com/img.png"
      assert html =~ "Test Image"
      refute html =~ "ring-1"
    end

    test "renders image with edit borders in :edit mode", %{block: block} do
      assigns = %{block: block}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:edit} active={false} />
        """)

      assert html =~ "test.com/img.png"
      assert html =~ "border-base-300"
      assert html =~ "hover:border-primary/50"
    end

    test "renders placeholder if url is missing in :review mode", %{empty_block: empty_block} do
      assigns = %{empty_block: empty_block}

      html =
        rendered_to_string(~H"""
        <.content_block block={@empty_block} mode={:review} />
        """)

      assert html =~ "Image not uploaded yet"
      assert html =~ "hero-photo"
    end
  end

  describe "content_block/1 :video" do
    setup do
      block =
        insert(:block,
          type: :video,
          content: %{"url" => "http://test.com/vid.mp4", "controls" => true}
        )

      empty_block = insert(:block, type: :video, content: %{})
      %{block: block, empty_block: empty_block}
    end

    test "renders video player in :play mode", %{block: block} do
      assigns = %{block: block}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:play} />
        """)

      assert html =~ "test.com/vid.mp4"
      assert html =~ "<video"
      refute html =~ "ring-1"
    end

    test "renders video with edit borders in :edit mode", %{block: block} do
      assigns = %{block: block}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:edit} active={true} />
        """)

      assert html =~ "test.com/vid.mp4"
      assert html =~ "border-primary"
      assert html =~ "border-2"
    end

    test "renders placeholder if url is missing in :review mode", %{empty_block: empty_block} do
      assigns = %{empty_block: empty_block}

      html =
        rendered_to_string(~H"""
        <.content_block block={@empty_block} mode={:review} />
        """)

      assert html =~ "Video not uploaded yet"
      assert html =~ "hero-video-camera"
    end
  end

  describe "content_block/1 :attachment" do
    setup do
      block =
        insert(:block,
          type: :attachment,
          content: %{
            "description" => %{"text" => "Study materials"},
            "files" => [%{"name" => "CheatSheet.pdf", "url" => "http://test.com/file.pdf"}]
          }
        )

      %{block: block}
    end

    test "renders files list in :play mode", %{block: block} do
      assigns = %{block: block}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:play} />
        """)

      assert html =~ "Study materials"
      assert html =~ "CheatSheet.pdf"
      assert html =~ "test.com/file.pdf"
      refute html =~ "ring-1"
    end

    test "renders with edit borders in :edit mode", %{block: block} do
      assigns = %{block: block}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:edit} active={true} />
        """)

      assert html =~ "CheatSheet.pdf"
      assert html =~ "border-primary"
      assert html =~ "border-2"
    end

    test "renders files in :review mode without edit borders", %{block: block} do
      assigns = %{block: block}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:review} />
        """)

      assert html =~ "CheatSheet.pdf"
      refute html =~ "ring-primary"
      assert html =~ "mb-10"
    end
  end

  describe "content_block/1 :code" do
    setup do
      block =
        insert(:block,
          type: :code,
          content: %{
            "language" => "python",
            "initial_code" => "def main():\n  print(\"Hello\")\nend"
          }
        )

      %{block: block}
    end

    test "renders code snippet cleanly in :play mode", %{block: block} do
      assigns = %{block: block}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:play} />
        """)

      assert html =~ "python"
      assert html =~ "def main()"
      refute html =~ "ring-1"
      assert html =~ "mb-10"
    end

    test "renders code block with borders in :edit mode", %{block: block} do
      assigns = %{block: block}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:edit} active={true} />
        """)

      assert html =~ "python"
      assert html =~ "border-primary"
      assert html =~ "border-2"
    end

    test "renders code block cleanly in :review mode", %{block: block} do
      assigns = %{block: block}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:review} />
        """)

      assert html =~ "def main():"
      refute html =~ "ring-primary"
      assert html =~ "mb-10"
    end
  end

  describe "content_block/1 :quiz_question (single choice)" do
    setup do
      block =
        insert(:block,
          type: :quiz_question,
          content: %{
            "question_type" => "single",
            "body" => %{"text" => "Pick one"},
            "options" => [
              %{"id" => "o1", "text" => "Correct Opt", "is_correct" => true},
              %{"id" => "o2", "text" => "Wrong Opt", "is_correct" => false}
            ]
          }
        )

      %{block: block}
    end

    test "renders in :edit mode with disabled inputs and edit styles", %{block: block} do
      assigns = %{block: block}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:edit} active={true} />
        """)

      assert html =~ "Pick one"
      assert html =~ "Correct Opt"
      assert html =~ "radio"
      assert html =~ " disabled"
      assert html =~ "border-primary"
      assert html =~ "pointer-events-none"
    end

    test "renders active inputs and preserves student answers in :play mode", %{block: block} do
      assigns = %{block: block, answers: %{block.id => "o1"}}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:play} answers={@answers} />
        """)

      assert html =~ "Correct Opt"
      assert html =~ "radio"
      assert html =~ "checked"
      refute html =~ " disabled"
    end

    test "renders read-only results with feedback in :review mode", %{block: block} do
      sub = %{score: 0, content: %{"selected_choices" => ["o2"]}}
      assigns = %{block: block, submission: sub}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:review} submission={@submission} />
        """)

      assert html =~ " disabled"
      assert html =~ "bg-error/10"
      assert html =~ "border-success"
    end

    test "renders in :preview mode with disabled inputs and pointer-events-none", %{block: block} do
      assigns = %{block: block}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:preview} />
        """)

      assert html =~ "Pick one"
      assert html =~ " disabled"
      assert html =~ "pointer-events-none"
      assert html =~ "cursor-default"
    end
  end

  describe "content_block/1 :quiz_question (multiple choice)" do
    setup do
      block =
        insert(:block,
          type: :quiz_question,
          content: %{
            "question_type" => "multiple",
            "body" => %{"text" => "Pick many"},
            "options" => [
              %{"id" => "o1", "text" => "Opt A", "is_correct" => true},
              %{"id" => "o2", "text" => "Opt B", "is_correct" => true}
            ]
          }
        )

      %{block: block}
    end

    test "renders in :edit mode with disabled checkboxes", %{block: block} do
      assigns = %{block: block}
      html = rendered_to_string(~H"<.content_block block={@block} mode={:edit} active={false} />")
      assert html =~ "Pick many"
      assert html =~ "checkbox"
      assert html =~ " disabled"
      assert html =~ "pointer-events-none"
    end

    test "renders active checkboxes with multiple selections in :play mode", %{block: block} do
      assigns = %{block: block, answers: %{block.id => ["o1", "o2"]}}

      html =
        rendered_to_string(~H"<.content_block block={@block} mode={:play} answers={@answers} />")

      assert html =~ "checkbox"
      refute html =~ " disabled"
    end

    test "renders read-only results in :review mode", %{block: block} do
      sub = %{score: 50, content: %{"selected_choices" => ["o1"]}}
      assigns = %{block: block, submission: sub}

      html =
        rendered_to_string(
          ~H"<.content_block block={@block} mode={:review} submission={@submission} />"
        )

      assert html =~ " disabled"
      assert html =~ "bg-success/10"
      assert html =~ "border-success"
    end
  end

  describe "content_block/1 :quiz_question (open / essay)" do
    setup do
      block =
        insert(:block,
          type: :quiz_question,
          content: %{
            "question_type" => "open",
            "body" => %{"text" => "Write your thoughts"}
          }
        )

      %{block: block}
    end

    test "renders disabled textarea in :edit mode", %{block: block} do
      assigns = %{block: block}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:edit} active={true} />
        """)

      assert html =~ "<textarea"
      assert html =~ "Write your thoughts"
      assert html =~ " disabled"
    end

    test "renders active textarea with typing state in :play mode", %{block: block} do
      assigns = %{block: block, answers: %{block.id => "My cool essay"}}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:play} answers={@answers} />
        """)

      assert html =~ "<textarea"
      assert html =~ "My cool essay"
      refute html =~ ~r/ disabled(?!:)/
    end

    test "renders student essay in disabled textarea in :review mode", %{block: block} do
      sub = %{content: %{"text_answer" => "Student submitted text"}}
      assigns = %{block: block, submission: sub}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:review} submission={@submission} />
        """)

      assert html =~ "Student submitted text"
      assert html =~ " disabled"
    end
  end

  describe "content_block/1 :quiz_question (exact_match / ctf)" do
    setup do
      block =
        insert(:block,
          type: :quiz_question,
          content: %{
            "question_type" => "exact_match",
            "body" => %{"text" => "Enter the flag"},
            "correct_answer" => "athena{123}"
          }
        )

      %{block: block}
    end

    test "renders disabled text input in :edit mode", %{block: block} do
      assigns = %{block: block}
      html = rendered_to_string(~H"<.content_block block={@block} mode={:edit} active={false} />")
      assert html =~ "<input"
      assert html =~ "type=\"text\""
      assert html =~ " disabled"
    end

    test "renders active text input with user value in :play mode", %{block: block} do
      assigns = %{block: block, answers: %{block.id => "athena{wrong}"}}

      html =
        rendered_to_string(~H"<.content_block block={@block} mode={:play} answers={@answers} />")

      assert html =~ "athena{wrong}"
      assert html =~ "type=\"text\""
      refute html =~ ~r/ disabled(?!:)/
    end

    test "renders disabled input with student answer and correct flag in :review mode", %{
      block: block
    } do
      sub = %{score: 0, content: %{"text_answer" => "athena{try_harder}"}}
      assigns = %{block: block, submission: sub}

      html =
        rendered_to_string(
          ~H"<.content_block block={@block} mode={:review} submission={@submission} />"
        )

      assert html =~ "athena{try_harder}"
      assert html =~ " disabled"
      assert html =~ "Correct:"
      assert html =~ "athena{123}"
    end
  end

  describe "content_block/1 :quiz_exam" do
    setup do
      block =
        insert(:block,
          type: :quiz_exam,
          content: %{
            "count" => 15,
            "time_limit" => 60
          }
        )

      %{block: block}
    end

    test "renders exam banner with borders in :edit mode", %{block: block} do
      assigns = %{block: block}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:edit} active={true} />
        """)

      assert html =~ "Final Exam"
      assert html =~ "15 Questions"
      assert html =~ "60 Min"
      assert html =~ "border-primary"
      refute html =~ "Start Exam"
    end

    test "renders start button in :play mode", %{block: block} do
      assigns = %{block: block}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:play} />
        """)

      assert html =~ "Final Exam"
      assert html =~ "Start Exam"
      assert html =~ "hero-play-solid"
      refute html =~ "ring-primary"
    end

    test "renders read-only banner without start button in :review mode", %{block: block} do
      assigns = %{block: block}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:review} />
        """)

      assert html =~ "Final Exam"
      assert html =~ "15 Questions"
      refute html =~ "Start Exam"
      refute html =~ "hero-play-solid"
      refute html =~ "ring-primary"
    end

    test "renders read-only banner without start button in :preview mode", %{block: block} do
      assigns = %{block: block}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:preview} />
        """)

      assert html =~ "Final Exam"
      assert html =~ "15 Questions"
      refute html =~ "Start Exam"
      assert html =~ "cursor-default"
    end
  end

  describe "content_block/1 :file_assignment" do
    setup do
      block =
        insert(:block,
          type: :file_assignment,
          content: %{
            "body" => %{"text" => "Please submit your project files."},
            "max_files" => 3
          }
        )

      %{block: block}
    end

    test "renders instruction banner and no upload button in :edit mode", %{block: block} do
      assigns = %{block: block}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:edit} active={true} />
        """)

      assert html =~ "Student will be able to upload up to 3 file(s)"
      assert html =~ "Please submit your project files"
      assert html =~ "border-primary"
      refute html =~ "Select Files"
      refute html =~ "request_media_upload"
    end

    test "renders upload area and select button in :play mode (initial state)", %{block: block} do
      assigns = %{block: block}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:play} />
        """)

      assert html =~ "You can upload 3 more file(s)"
      assert html =~ "Select Files"
      assert html =~ "request_media_upload"
      assert html =~ "hero-cloud-arrow-up"
      refute html =~ "Maximum file limit reached"
      refute html =~ "remove_pending_file"
    end

    test "renders pending files and reduces remaining count in :play mode", %{block: block} do
      assigns = %{
        block: block,
        pending_file_urls: %{
          block.id => ["https://s3.aws/file1.pdf", "https://s3.aws/file2.pdf"]
        }
      }

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:play} pending_file_urls={@pending_file_urls} />
        """)

      assert html =~ "You can upload 1 more file(s)"
      assert html =~ "file1.pdf"
      assert html =~ "file2.pdf"
      assert html =~ "remove_pending_file"
      assert html =~ "hero-document-check"
    end

    test "hides upload area and shows limit reached message when max_files is met in :play mode",
         %{
           block: block
         } do
      assigns = %{
        block: block,
        pending_file_urls: %{
          block.id => [
            "https://s3.aws/f1.pdf",
            "https://s3.aws/f2.pdf",
            "https://s3.aws/f3.pdf"
          ]
        }
      }

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:play} pending_file_urls={@pending_file_urls} />
        """)

      assert html =~ "Maximum file limit reached."
      assert html =~ "hero-lock-closed"
      refute html =~ "You can upload"
      refute html =~ "Select Files"
    end

    test "renders submitted files in :review mode and hides upload controls", %{block: block} do
      sub = %{
        content: %{
          "file_urls" => ["https://s3.aws/submitted1.pdf", "https://s3.aws/submitted2.pdf"]
        }
      }

      assigns = %{block: block, submission: sub}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:review} submission={@submission} />
        """)

      assert html =~ "submitted1.pdf"
      assert html =~ "submitted2.pdf"
      assert html =~ "hero-document-arrow-down"
      assert html =~ ~s(data-readonly="true")
      refute html =~ "Select Files"
      refute html =~ "Maximum file limit reached"
      refute html =~ "remove_pending_file"
    end

    test "renders in :preview mode as read-only without any interactive elements", %{block: block} do
      assigns = %{block: block}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:preview} />
        """)

      assert html =~ ~s(data-readonly="true")
      assert html =~ "cursor-default"
      refute html =~ "Select Files"
      refute html =~ "request_media_upload"
    end
  end

  describe "content_block/1 draft fallback" do
    test "quiz_question (open) renders draft text when no submission or answers present" do
      block = insert(:block, type: :quiz_question, content: %{"question_type" => "open"})
      draft = %{"type" => :quiz_question, "text_answer" => "My saved draft"}
      assigns = %{block: block, draft: draft}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:play} draft={@draft} />
        """)

      assert html =~ "My saved draft"
      assert html =~ "<textarea"
    end

    test "quiz_question (exact_match) renders draft text when no submission or answers present" do
      block = insert(:block, type: :quiz_question, content: %{"question_type" => "exact_match"})
      draft = %{"type" => :quiz_question, "text_answer" => "draft_flag{123}"}
      assigns = %{block: block, draft: draft}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:play} draft={@draft} />
        """)

      assert html =~ "draft_flag{123}"
      assert html =~ ~s(value="draft_flag{123}")
    end

    test "quiz_question (single) renders draft selected_choices when no submission or answers present" do
      block =
        insert(:block,
          type: :quiz_question,
          content: %{
            "question_type" => "single",
            "options" => [
              %{"id" => "opt1", "text" => "Option 1", "is_correct" => true},
              %{"id" => "opt2", "text" => "Option 2", "is_correct" => false}
            ]
          }
        )

      draft = %{"type" => :quiz_question, "selected_choices" => ["opt1"]}
      assigns = %{block: block, draft: draft}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:play} draft={@draft} />
        """)

      assert html =~ "Option 1"
      assert html =~ "Option 2"
      assert html =~ ~s(value="opt1" checked)
      refute html =~ ~s(value="opt2" checked)
    end

    test "quiz_question (multiple) renders draft selected_choices when no submission or answers present" do
      block =
        insert(:block,
          type: :quiz_question,
          content: %{
            "question_type" => "multiple",
            "options" => [
              %{"id" => "opt1", "text" => "Option A", "is_correct" => true},
              %{"id" => "opt2", "text" => "Option B", "is_correct" => true},
              %{"id" => "opt3", "text" => "Option C", "is_correct" => false}
            ]
          }
        )

      draft = %{"type" => :quiz_question, "selected_choices" => ["opt1", "opt2"]}
      assigns = %{block: block, draft: draft}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:play} draft={@draft} />
        """)

      assert html =~ "Option A"
      assert html =~ "Option B"
      assert html =~ "Option C"
      assert html =~ ~s(value="opt1" checked)
      assert html =~ ~s(value="opt2" checked)
      refute html =~ ~s(value="opt3" checked)
    end

    test "quiz_question prioritizes submission over draft" do
      block = insert(:block, type: :quiz_question, content: %{"question_type" => "open"})
      draft = %{"type" => :quiz_question, "text_answer" => "Draft answer"}
      submission = %{content: %{"text_answer" => "Final submission"}}
      assigns = %{block: block, draft: draft, submission: submission}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:review} submission={@submission} draft={@draft} />
        """)

      assert html =~ "Final submission"
      refute html =~ "Draft answer"
    end

    test "quiz_question prioritizes answers over draft" do
      block = insert(:block, type: :quiz_question, content: %{"question_type" => "open"})
      draft = %{"type" => :quiz_question, "text_answer" => "Draft answer"}
      answers = %{block.id => "Live answer"}
      assigns = %{block: block, draft: draft, answers: answers}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:play} answers={@answers} draft={@draft} />
        """)

      assert html =~ "Live answer"
      refute html =~ "Draft answer"
    end

    test "code block renders draft code when no submission or answers present" do
      block =
        insert(:block,
          type: :code,
          content: %{"language" => "python", "initial_code" => "# template"}
        )

      draft = %{"type" => :code, "code" => "print(draft code)"}
      assigns = %{block: block, draft: draft}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:play} draft={@draft} />
        """)

      assert html =~ "print("
      assert html =~ "draft code"
    end

    test "code block prioritizes submission over draft" do
      block = insert(:block, type: :code, content: %{"language" => "python"})
      draft = %{"type" => :code, "code" => "# draft"}

      submission = %Athena.Learning.Submission{
        content: %{"code" => "# final submission", "type" => "code"},
        status: :graded,
        score: 100
      }

      assigns = %{block: block, draft: draft, submission: submission}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:review} submission={@submission} draft={@draft} />
        """)

      assert html =~ "# final submission"
      refute html =~ "# draft"
    end

    test "code block prioritizes answers over draft" do
      block = insert(:block, type: :code, content: %{"language" => "python"})
      draft = %{"type" => :code, "code" => "# draft"}
      answers = %{block.id => %{"code" => "# live answer"}}
      assigns = %{block: block, draft: draft, answers: answers}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:play} answers={@answers} draft={@draft} />
        """)

      assert html =~ "# live answer"
      refute html =~ "# draft"
    end

    test "file_assignment merges draft file_urls into pending_urls" do
      block = insert(:block, type: :file_assignment, content: %{"max_files" => 3})

      assigns = %{
        block: block,
        pending_file_urls: %{
          block.id => ["https://s3.aws/draft1.pdf", "https://s3.aws/pending1.pdf"]
        }
      }

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:play} pending_file_urls={@pending_file_urls} />
        """)

      assert html =~ "draft1.pdf"
      assert html =~ "pending1.pdf"
      assert html =~ "You can upload 1 more file(s)"
    end

    test "file_assignment shows draft files when no pending_urls present" do
      block = insert(:block, type: :file_assignment, content: %{"max_files" => 2})

      assigns = %{
        block: block,
        pending_file_urls: %{
          block.id => ["https://s3.aws/draft1.pdf", "https://s3.aws/draft2.pdf"]
        }
      }

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:play} pending_file_urls={@pending_file_urls} />
        """)

      assert html =~ "draft1.pdf"
      assert html =~ "draft2.pdf"
      assert html =~ "Maximum file limit reached"
    end

    test "file_assignment prioritizes submission over draft" do
      block = insert(:block, type: :file_assignment, content: %{"max_files" => 2})
      draft = %{"type" => :file_assignment, "file_urls" => ["https://s3.aws/draft.pdf"]}
      submission = %{content: %{"file_urls" => ["https://s3.aws/final.pdf"]}}
      assigns = %{block: block, draft: draft, submission: submission}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:review} submission={@submission} draft={@draft} />
        """)

      assert html =~ "final.pdf"
      refute html =~ "draft.pdf"
    end

    test "quiz_question includes phx-change handler for save_draft in play mode" do
      block = insert(:block, type: :quiz_question, content: %{"question_type" => "open"})
      assigns = %{block: block}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:play} />
        """)

      assert html =~ ~s(phx-change="save_draft")
      assert html =~ ~s(phx-debounce="500")
    end

    test "code block includes phx-change handler for save_draft in play mode" do
      block = insert(:block, type: :code, content: %{"language" => "python"})
      assigns = %{block: block}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:play} />
        """)

      assert html =~ ~s(phx-change="save_draft")
      assert html =~ ~s(phx-debounce="500")
    end

    test "quiz_question does not include phx-change in review mode" do
      block = insert(:block, type: :quiz_question, content: %{"question_type" => "open"})
      submission = %{content: %{"text_answer" => "answer"}}
      assigns = %{block: block, submission: submission}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:review} submission={@submission} />
        """)

      refute html =~ ~s(phx-change="save_draft")
    end
  end
end
