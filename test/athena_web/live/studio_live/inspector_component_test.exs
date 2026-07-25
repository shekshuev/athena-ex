defmodule AthenaWeb.StudioLive.Builder.InspectorComponentTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory
  alias AthenaWeb.StudioLive.Builder.InspectorComponent

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

    test "renders reset_waterline checkbox regardless of visibility", %{section: section} do
      html =
        render_component(InspectorComponent,
          id: "inspector",
          active_section: section,
          active_block: nil
        )

      assert html =~ "Reset Waterline"
      assert html =~ "Ignore previous locked lessons"
      assert html =~ ~s(name="section[access_rules][reset_waterline]")
    end
  end

  describe "Block Inspector" do
    setup do
      %{block: build(:block, type: :text)}
    end

    test "renders text block fields and basic progression rules", %{block: block} do
      html =
        render_component(InspectorComponent,
          id: "inspector",
          active_section: nil,
          active_block: block
        )

      assert html =~ "text Block"
      assert html =~ "Who can see this block?"
      assert html =~ ~s(id="block-inspector-form-#{block.id}")

      assert html =~ "Progression Rules"
      assert html =~ "How to unlock the next block?"
      assert html =~ ~s(name="block[completion_rule][type]")

      assert html =~ "Require Button Click"
      refute html =~ "Require Submission"

      refute html =~ "Execution Settings"
      refute html =~ "Programming Language"
      assert html =~ "Save to Library"
      assert html =~ "Delete Block"
    end

    test "renders button_text input when completion rule is button", %{block: base_block} do
      block = %{
        base_block
        | completion_rule: %Athena.Content.CompletionRule{type: :button, button_text: "Let's go!"}
      }

      html =
        render_component(InspectorComponent,
          id: "inspector",
          active_section: nil,
          active_block: block
        )

      assert html =~ "Button Text"
      assert html =~ ~s(name="block[completion_rule][button_text]")
      assert html =~ "Let&#39;s go!"
    end

    test "renders code block fields and advanced progression rules", %{block: base_block} do
      block = %{
        base_block
        | type: :code,
          content: %{
            "language" => "python3",
            "time_limit" => 1.0,
            "memory_limit" => 65_536,
            "initial_code" => "",
            "solution_code" => ""
          }
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
      assert html =~ "Time Limit"
      assert html =~ "Memory"

      assert html =~ "Require Submission"
      assert html =~ "Pass Auto-Grade"
    end

    test "renders min_score input when completion rule is pass_auto_grade", %{block: base_block} do
      block = %{
        base_block
        | type: :code,
          completion_rule: %Athena.Content.CompletionRule{type: :pass_auto_grade, min_score: 85}
      }

      html =
        render_component(InspectorComponent,
          id: "inspector",
          active_section: nil,
          active_block: block
        )

      assert html =~ "Minimum Score to Pass"
      assert html =~ ~s(name="block[completion_rule][min_score]")
      assert html =~ "85"
    end

    test "renders image block media settings", %{block: base_block} do
      block = %{
        base_block
        | type: :image,
          content: %{"alt" => "My cool image", "url" => nil}
      }

      html =
        render_component(InspectorComponent,
          id: "inspector",
          active_section: nil,
          active_block: block
        )

      assert html =~ "image Block"
      assert html =~ "Media Settings"
      assert html =~ "Upload File"
      assert html =~ ~s(phx-click="request_media_upload")
      assert html =~ ~s(phx-value-media_type="image")

      assert html =~ "Alt Text"
      assert html =~ ~s(name="block[content][alt]")
      assert html =~ "My cool image"

      refute html =~ "Poster URL"
    end

    test "renders video block media settings", %{block: base_block} do
      block = %{
        base_block
        | type: :video,
          content: %{"poster_url" => "http://test.com/poster.jpg", "url" => nil}
      }

      html =
        render_component(InspectorComponent,
          id: "inspector",
          active_section: nil,
          active_block: block
        )

      assert html =~ "video Block"
      assert html =~ "Media Settings"
      assert html =~ "Upload File"
      assert html =~ ~s(phx-click="request_media_upload")
      assert html =~ ~s(phx-value-media_type="video")

      assert html =~ "Poster URL"
      assert html =~ ~s(name="block[content][poster_url]")
      assert html =~ "http://test.com/poster.jpg"

      refute html =~ "Alt Text"
    end

    test "shows 'Replace File' button when media url is already present", %{block: base_block} do
      block = %{
        base_block
        | type: :image,
          content: %{"url" => "http://s3.com/file.jpg", "alt" => ""}
      }

      html =
        render_component(InspectorComponent,
          id: "inspector",
          active_section: nil,
          active_block: block
        )

      assert html =~ "Replace File"
      refute html =~ "Upload File"
    end

    test "renders quiz question block with open type by default", %{block: base_block} do
      block = %{
        base_block
        | type: :quiz_question,
          content: %{"question_type" => "open", "general_explanation" => "Think hard!"}
      }

      html =
        render_component(InspectorComponent,
          id: "inspector",
          active_section: nil,
          active_block: block
        )

      assert html =~ "quiz question Block"
      assert html =~ "Question Settings"
      assert html =~ "Question Type"
      assert html =~ ~s(name="block[content][question_type]")

      assert html =~ "General Explanation"
      assert html =~ "Think hard!"
      refute html =~ "Case Sensitive"
    end

    test "renders case_sensitive checkbox when quiz type is exact_match", %{block: base_block} do
      block = %{
        base_block
        | type: :quiz_question,
          content: %{"question_type" => "exact_match", "case_sensitive" => true}
      }

      html =
        render_component(InspectorComponent,
          id: "inspector",
          active_section: nil,
          active_block: block
        )

      assert html =~ "Case Sensitive"
      assert html =~ ~s(name="block[content][case_sensitive]")
      assert html =~ ~s(checked)
    end

    test "renders default values for fresh quiz exam block", %{block: base_block} do
      block = %{
        base_block
        | type: :quiz_exam,
          content: %{}
      }

      html =
        render_component(InspectorComponent,
          id: "inspector",
          active_section: nil,
          active_block: block
        )

      assert html =~ "Assessment Session Block"
      assert html =~ "Assessment Session Configuration"

      assert html =~ ~s(name="block[content][count]")
      assert html =~ ~s(value="10")
    end

    test "renders default values for fresh ticket exam block", %{block: base_block} do
      block = %{
        base_block
        | type: :ticket_exam,
          content: %{}
      }

      html =
        render_component(InspectorComponent,
          id: "inspector",
          active_section: nil,
          active_block: block
        )

      assert html =~ "Ticket Assessment Block"
      assert html =~ "Ticket Assessment Configuration"
      assert html =~ ~s(name="block[content][time_limit]")
    end

    test "renders ticket exam configuration fields and slots", %{block: base_block} do
      block = %{
        base_block
        | type: :ticket_exam,
          content: %{
            "time_limit" => 45,
            "slots" => [
              %{"id" => "slot1", "tags" => ["db", "theory"]}
            ]
          }
      }

      html =
        render_component(InspectorComponent,
          id: "inspector",
          active_section: nil,
          active_block: block
        )

      assert html =~ ~s(name="block[content][time_limit]")
      assert html =~ "45"
      assert html =~ ~s(name="block[content][slots][0][tags_string]")
      assert html =~ "db, theory"
      assert html =~ "Add Slot"
      assert html =~ "Remove Slot"
    end

    test "renders correct progression rules for quiz exam blocks", %{block: base_block} do
      block = %{
        base_block
        | type: :quiz_exam,
          content: %{}
      }

      html =
        render_component(InspectorComponent,
          id: "inspector",
          active_section: nil,
          active_block: block
        )

      assert html =~ "Progression Rules"
      assert html =~ "How to unlock the next block?"

      assert html =~ "None (Scroll past)"
      assert html =~ "Require Submission"
      assert html =~ "Pass Auto-Grade"
    end

    test "renders sql code block execution settings with time limit and without memory limit", %{
      block: base_block
    } do
      block = %{
        base_block
        | type: :code,
          content: %{
            "language" => "sql",
            "time_limit" => 2.0,
            "body" => %{
              "evaluation_mode" => "query_result",
              "setup_sql" => "CREATE TABLE users (id INT);",
              "solution_sql" => "SELECT * FROM users;"
            }
          }
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
      assert html =~ "Evaluation Mode"
      assert html =~ "Query Result"
      assert html =~ "State Verification"
      assert html =~ ~s(name="block[content][body][evaluation_mode]")

      assert html =~ "Time Limit (s)"
      assert html =~ ~s(name="block[content][time_limit]")

      refute html =~ "Memory (KB)"
      refute html =~ ~s(name="block[content][memory_limit]")

      assert html =~ "Max Attempts"
      assert html =~ ~s(name="block[content][max_attempts]")
    end
  end
end
