defmodule AthenaWeb.SurveyComponentsTest do
  @moduledoc """
  The shared question renderer. Asserts the *form contract* - that every type
  posts `question_id` plus a `value[...]` shape matching what
  `Athena.Surveys.AnswerParams` casts - because that contract is what lets
  one player handler serve all ten types and the preview post what the
  player posts.
  """
  use AthenaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Athena.Factory

  alias Athena.Surveys.{QuestionTypes, SurveyAnswer}
  alias AthenaWeb.SurveyComponents

  defp render_question(question, opts \\ []) do
    render_component(&SurveyComponents.question/1,
      question: question,
      mode: Keyword.get(opts, :mode, :play),
      answers: Keyword.get(opts, :answers, %{}),
      number: Keyword.get(opts, :number)
    )
  end

  defp question(type, config \\ nil) do
    build(:survey_question,
      id: Ecto.UUID.generate(),
      type: type,
      config: config || QuestionTypes.default_config(type),
      body: tiptap_doc("How did it go?")
    )
  end

  describe "the form contract" do
    test "every answerable type posts question_id" do
      for type <- QuestionTypes.all() -- [:ranking] do
        html = render_question(question(type))

        assert html =~ ~s(name="question_id"), "#{type} did not post question_id"
        assert html =~ "phx-change", "#{type} has no change binding"
      end
    end

    test "Enter in a text field submits rather than reloading the page" do
      html = render_question(question(:open_text))

      # Without phx-submit, pressing Enter does a real form POST and the
      # answer is lost.
      assert html =~ "phx-submit"
    end

    test "input names match what AnswerParams casts" do
      expected = [
        {:single_choice, ~s(name="value[choice_id]")},
        {:multiple_choice, ~s(name="value[choice_ids][]")},
        {:dichotomous, ~s(name="value[choice_id]")},
        {:open_text, ~s(name="value[text]")},
        {:numeric, ~s(name="value[number]")},
        {:scale, ~s(name="value[number]")},
        {:nps, ~s(name="value[number]")}
      ]

      for {type, name} <- expected do
        assert render_question(question(type)) =~ name, "#{type} is missing #{name}"
      end
    end

    test "a checkbox group carries the blank hidden input it needs" do
      html = render_question(question(:multiple_choice))

      # Keeps the key present when every box is cleared, so "I unchecked
      # everything" arrives as an answer rather than as silence.
      assert html =~ ~s(<input type="hidden" name="value[choice_ids][]" value="")
    end

    test "a matrix posts one form per row, each carrying its row id" do
      rows = [
        %{"id" => Ecto.UUID.generate(), "text" => "Pace"},
        %{"id" => Ecto.UUID.generate(), "text" => "Depth"}
      ]

      html =
        render_question(
          question(:multi_scale, %{"rows" => rows, "min" => 1, "max" => 5, "step" => 1})
        )

      for row <- rows do
        assert html =~ ~s(value="#{row["id"]}")
        assert html =~ row["text"]
      end

      # One form per row, since a matrix stores one answer per row.
      assert length(String.split(html, "phx-change")) - 1 == 2
    end

    test "matching posts a select per left item keyed by its id" do
      pairs = [
        %{"id" => "l1", "left" => "Lecture", "right" => "Hall A"},
        %{"id" => "l2", "left" => "Seminar", "right" => "Room 3"}
      ]

      html = render_question(question(:matching, %{"pairs" => pairs}))

      assert html =~ ~s(name="value[pairs][l1]")
      assert html =~ ~s(name="value[pairs][l2]")
    end
  end

  describe "rendering the question itself" do
    test "the prompt, helper text and required marker show" do
      q = %{question(:scale) | help_text: "Be honest", required: true}

      html = render_question(q, number: 3)

      assert html =~ "How did it go?"
      assert html =~ "Be honest"
      assert html =~ ~r/tabular-nums[^>]*>\s*3\s*</
      assert html =~ "text-error"
    end

    test "a scale renders one point per step, honouring the bounds" do
      html = render_question(question(:scale, %{"min" => 1, "max" => 7, "step" => 2}))

      for point <- [1, 3, 5, 7] do
        assert html =~ ~s(value="#{point}")
      end

      refute html =~ ~s(value="2")
    end

    test "pole labels show when given" do
      html =
        render_question(
          question(:scale, %{
            "min" => 1,
            "max" => 5,
            "step" => 1,
            "min_label" => "Never",
            "max_label" => "Always"
          })
        )

      assert html =~ "Never"
      assert html =~ "Always"
    end

    test "nps is fixed to 0-10 regardless of config" do
      html = render_question(question(:nps))

      for point <- 0..10, do: assert(html =~ ~s(value="#{point}"))
    end

    test "a write-in option only appears when allowed" do
      {config, _ids} = choice_config(["Yes", "No"])

      refute render_question(question(:single_choice, config)) =~ "Other"

      allowed = Map.put(config, "other_allowed", true)
      assert render_question(question(:single_choice, allowed)) =~ "Other"
    end

    test "a selection range is spelled out for the respondent" do
      {config, _ids} = choice_config(["A", "B", "C"])
      config = Map.merge(config, %{"min_select" => 1, "max_select" => 2})

      assert render_question(question(:multiple_choice, config)) =~ "Choose between"
    end
  end

  describe "existing answers come back pre-filled" do
    test "a chosen option is checked" do
      {config, [first, second]} = choice_config(["Yes", "No"])
      q = question(:single_choice, config)
      answers = %{{q.id, ""} => %SurveyAnswer{value_choice_ids: [second]}}

      html = render_question(q, answers: answers)

      # The chosen radio is checked and the other is not.
      assert html =~ ~r/value="#{second}"[^>]*checked/
      refute html =~ ~r/value="#{first}"[^>]*checked/
    end

    test "a scale answer is selected" do
      q = question(:scale)
      answers = %{{q.id, ""} => %SurveyAnswer{value_numeric: 4.0}}

      assert render_question(q, answers: answers) =~ ~r/value="4"[^>]*checked/
    end

    test "text comes back in the field" do
      q = question(:open_text)
      answers = %{{q.id, ""} => %SurveyAnswer{value_text: "Loved the labs"}}

      assert render_question(q, answers: answers) =~ "Loved the labs"
    end
  end

  describe "review mode" do
    test "shows the answer read-only, with no form to change it" do
      q = question(:scale)
      answers = %{{q.id, ""} => %SurveyAnswer{value_numeric: 4.0}}

      html = render_question(q, mode: :review, answers: answers)

      refute html =~ "phx-change"
      assert html =~ "4"
    end

    test "distinguishes never-answered from deliberately skipped" do
      q = question(:scale)

      assert render_question(q, mode: :review) =~ "Not answered"

      skipped = %{{q.id, ""} => %SurveyAnswer{skipped: true}}
      assert render_question(q, mode: :review, answers: skipped) =~ "Skipped"
    end

    test "labels a choice answer rather than echoing its id" do
      {config, [first | _]} = choice_config(["Much too fast", "About right"])
      q = question(:single_choice, config)
      answers = %{{q.id, ""} => %SurveyAnswer{value_choice_ids: [first]}}

      html = render_question(q, mode: :review, answers: answers)

      assert html =~ "Much too fast"
      refute html =~ first
    end

    test "labels a write-in with what was written" do
      {config, _ids} = choice_config(["Yes", "No"])
      q = question(:single_choice, Map.put(config, "other_allowed", true))

      answers = %{
        {q.id, ""} => %SurveyAnswer{
          value_choice_ids: [QuestionTypes.other_choice_id()],
          value_text: "the field trip"
        }
      }

      assert render_question(q, mode: :review, answers: answers) =~ "the field trip"
    end

    test "a matrix lists every row with its own value" do
      row_a = Ecto.UUID.generate()
      row_b = Ecto.UUID.generate()

      q =
        question(:multi_scale, %{
          "rows" => [%{"id" => row_a, "text" => "Pace"}, %{"id" => row_b, "text" => "Depth"}],
          "min" => 1,
          "max" => 5,
          "step" => 1
        })

      answers = %{
        {q.id, ""} => %SurveyAnswer{value_numeric: 2.0},
        {q.id, row_a} => %SurveyAnswer{value_numeric: 2.0},
        {q.id, row_b} => %SurveyAnswer{value_numeric: 5.0}
      }

      html = render_question(q, mode: :review, answers: answers)

      assert html =~ "Pace"
      assert html =~ "Depth"
    end
  end

  describe "prompt_text/1" do
    test "flattens a TipTap document to plain text for labels and CSV cells" do
      assert SurveyComponents.prompt_text(tiptap_doc("How was the pace?")) == "How was the pace?"
      assert SurveyComponents.prompt_text(%{"type" => "doc", "content" => []}) == ""
      assert SurveyComponents.prompt_text(nil) == ""
    end
  end
end
