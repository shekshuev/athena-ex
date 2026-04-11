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
      assert html =~ "ring-primary"
      assert html =~ "ring-2"
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
      assert html =~ "ring-1"
      assert html =~ "hover:ring-primary/50"
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
      assert html =~ "ring-primary"
      assert html =~ "ring-2"
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
      assert html =~ "ring-primary"
      assert html =~ "ring-2"
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
            "language" => "elixir",
            "code" => "defmodule Athena do\n  IO.puts(\"Hello\")\nend"
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

      assert html =~ "elixir"
      assert html =~ "defmodule Athena do"
      refute html =~ "ring-1"
      assert html =~ "mb-10"
    end

    test "renders code block with borders in :edit mode", %{block: block} do
      assigns = %{block: block}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:edit} active={true} />
        """)

      assert html =~ "elixir"
      assert html =~ "ring-primary"
      assert html =~ "ring-2"
    end

    test "renders code block cleanly in :review mode", %{block: block} do
      assigns = %{block: block}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:review} />
        """)

      assert html =~ "defmodule Athena do"
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
      assert html =~ "ring-primary"
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
      sub = %{content: %{"selected_choices" => ["o2"]}}
      assigns = %{block: block, submission: sub}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:review} submission={@submission} />
        """)

      assert html =~ " disabled"
      assert html =~ "Student&#39;s Answer:"
      assert html =~ "Student&#39;s Choice"
      assert html =~ "Correct Option"
      assert html =~ "bg-error/10"
      assert html =~ "ring-success"
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

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:edit} active={false} />
        """)

      assert html =~ "Pick many"
      assert html =~ "checkbox"
      assert html =~ " disabled"
      assert html =~ "pointer-events-none"
    end

    test "renders active checkboxes with multiple selections in :play mode", %{block: block} do
      assigns = %{block: block, answers: %{block.id => ["o1", "o2"]}}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:play} answers={@answers} />
        """)

      assert html =~ "checkbox"
      refute html =~ " disabled"
    end

    test "renders read-only results in :review mode", %{block: block} do
      sub = %{content: %{"selected_choices" => ["o1"]}}
      assigns = %{block: block, submission: sub}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:review} submission={@submission} />
        """)

      assert html =~ " disabled"
      assert html =~ "Correct Option"
      assert html =~ "bg-success/10"
      assert html =~ "ring-success"
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
      assert html =~ "Student&#39;s Answer:"
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

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:edit} active={false} />
        """)

      assert html =~ "<input"
      assert html =~ "type=\"text\""
      assert html =~ " disabled"
    end

    test "renders active text input with user value in :play mode", %{block: block} do
      assigns = %{block: block, answers: %{block.id => "athena{wrong}"}}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:play} answers={@answers} />
        """)

      assert html =~ "athena{wrong}"
      assert html =~ "type=\"text\""
      refute html =~ ~r/ disabled(?!:)/
    end

    test "renders disabled input with student answer and correct flag in :review mode", %{
      block: block
    } do
      sub = %{content: %{"text_answer" => "athena{try_harder}"}}
      assigns = %{block: block, submission: sub}

      html =
        rendered_to_string(~H"""
        <.content_block block={@block} mode={:review} submission={@submission} />
        """)

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
      assert html =~ "ring-primary"
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
  end
end
