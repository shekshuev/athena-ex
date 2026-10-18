defmodule Athena.Surveys.QuestionsTest do
  @moduledoc """
  Question management: dense ordering, type changes, and the rule cleanup that
  has to happen alongside both.
  """
  use Athena.DataCase, async: true

  import Athena.Factory

  alias Athena.Surveys
  alias Athena.Surveys.{SurveyBranch, SurveyQuestion}

  defp positions(survey_id) do
    survey_id |> Surveys.list_questions() |> Enum.map(& &1.position)
  end

  defp ids(survey_id) do
    survey_id |> Surveys.list_questions() |> Enum.map(& &1.id)
  end

  describe "adding" do
    test "questions append in order with dense positions" do
      survey = insert(:survey)

      {:ok, _} = Surveys.add_question(survey, :scale)
      {:ok, _} = Surveys.add_question(survey, :open_text)
      {:ok, _} = Surveys.add_question(survey, :single_choice)

      assert positions(survey.id) == [0, 1, 2]
    end

    test "a new question is immediately valid and answerable" do
      survey = insert(:survey)

      for type <- Surveys.QuestionTypes.all() do
        assert {:ok, question} = Surveys.add_question(survey, type)
        assert question.config != %{}
        assert question.body["type"] == "doc"
      end
    end

    test "a new question lands on the last page" do
      survey = insert(:survey)
      insert(:survey_question, survey: survey, page: 2, position: 0)

      {:ok, question} = Surveys.add_question(survey, :scale)

      assert question.page == 2
    end
  end

  describe "updating" do
    test "a question's survey and position are not updatable here" do
      survey = insert(:survey)
      other = insert(:survey)
      question = insert(:survey_question, survey: survey, position: 0)

      {:ok, updated} =
        Surveys.update_question(question, %{
          "required" => true,
          "survey_id" => other.id,
          "position" => 99
        })

      assert updated.required
      assert updated.survey_id == survey.id
      assert updated.position == 0
    end

    test "an invalid config is refused and the stored one is untouched" do
      survey = insert(:survey)
      question = insert(:survey_question, survey: survey, type: :scale)

      assert {:error, _} =
               Surveys.update_question(question, %{"config" => %{"min" => 9, "max" => 1}})

      assert Repo.reload!(question).config["max"] == 5
    end
  end

  describe "changing a question's type" do
    test "replaces the config with the new type's defaults" do
      survey = insert(:survey)
      question = insert(:survey_question, survey: survey, type: :scale)

      {:ok, changed} = Surveys.change_question_type(question, :single_choice)

      assert changed.type == :single_choice
      assert length(changed.config["options"]) == 2
      refute Map.has_key?(changed.config, "min")
    end

    test "deletes rules that test the question, since they can never match again" do
      survey = insert(:survey)
      q1 = insert(:survey_question, survey: survey, type: :scale, position: 0)
      q2 = insert(:survey_question, survey: survey, type: :scale, position: 1)

      {:ok, _rule} =
        Surveys.add_branch(survey, q1, %{
          "action" => "goto_question",
          "target_question_id" => q2.id,
          "condition" => %{
            "logic" => "and",
            "clauses" => [%{"question_id" => q1.id, "op" => "lte", "value" => %{"number" => 2}}]
          }
        })

      assert Repo.aggregate(SurveyBranch, :count) == 1

      {:ok, _} = Surveys.change_question_type(q1, :open_text)

      assert Repo.aggregate(SurveyBranch, :count) == 0
    end

    test "deletes rules that merely target the question too" do
      survey = insert(:survey)
      q1 = insert(:survey_question, survey: survey, type: :scale, position: 0)
      q2 = insert(:survey_question, survey: survey, type: :scale, position: 1)
      q3 = insert(:survey_question, survey: survey, type: :scale, position: 2)

      {:ok, _} =
        Surveys.add_branch(survey, q1, %{
          "action" => "goto_question",
          "target_question_id" => q3.id,
          "condition" => %{
            "logic" => "and",
            "clauses" => [%{"question_id" => q1.id, "op" => "gte", "value" => %{"number" => 4}}]
          }
        })

      {:ok, _} = Surveys.change_question_type(q3, :open_text)

      assert Repo.aggregate(SurveyBranch, :count) == 0
      assert Repo.get(SurveyQuestion, q2.id)
    end
  end

  describe "deleting" do
    test "closes the gap so positions stay dense" do
      survey = insert(:survey)
      {:ok, _a} = Surveys.add_question(survey, :scale)
      {:ok, b} = Surveys.add_question(survey, :scale)
      {:ok, _c} = Surveys.add_question(survey, :scale)

      {:ok, _} = Surveys.delete_question(b)

      assert positions(survey.id) == [0, 1]
    end

    test "takes its own rules with it and drops rules aimed at it" do
      survey = insert(:survey)
      q1 = insert(:survey_question, survey: survey, type: :scale, position: 0)
      q2 = insert(:survey_question, survey: survey, type: :scale, position: 1)

      {:ok, _own} =
        Surveys.add_branch(survey, q1, %{
          "action" => "end_survey",
          "condition" => %{
            "logic" => "and",
            "clauses" => [%{"question_id" => q1.id, "op" => "lte", "value" => %{"number" => 1}}]
          }
        })

      {:ok, _aimed} =
        Surveys.add_branch(survey, q2, %{
          "action" => "goto_question",
          "target_question_id" => q1.id,
          "condition" => %{
            "logic" => "and",
            "clauses" => [%{"question_id" => q2.id, "op" => "gte", "value" => %{"number" => 4}}]
          }
        })

      {:ok, _} = Surveys.delete_question(q1)

      assert Repo.aggregate(SurveyBranch, :count) == 0
    end

    test "answers to a deleted question go with it" do
      survey = insert(:survey, status: :published)
      question = insert(:survey_question, survey: survey, type: :scale)
      course = insert(:course)

      {:ok, response} =
        Surveys.get_or_start_response(survey, insert(:account), %{course_id: course.id})

      {:ok, _} = Surveys.save_answer(response, question, %{"number" => 3})

      {:ok, _} = Surveys.delete_question(question)

      assert Surveys.list_answers(response.id) == []
    end
  end

  describe "duplicating" do
    test "inserts the copy immediately after the original" do
      survey = insert(:survey)
      {:ok, a} = Surveys.add_question(survey, :scale)
      {:ok, c} = Surveys.add_question(survey, :open_text)

      {:ok, copy} = Surveys.duplicate_question(a)

      assert ids(survey.id) == [a.id, copy.id, c.id]
      assert positions(survey.id) == [0, 1, 2]
    end

    test "regenerates option ids so the copy's answers cannot be confused" do
      survey = insert(:survey)
      {config, original_ids} = choice_config(["A", "B"])
      question = insert(:survey_question, survey: survey, type: :single_choice, config: config)

      {:ok, copy} = Surveys.duplicate_question(question)

      copied_ids = Enum.map(copy.config["options"], & &1["id"])

      assert length(copied_ids) == 2
      assert Enum.map(copy.config["options"], & &1["text"]) == ["A", "B"]
      refute Enum.any?(copied_ids, &(&1 in original_ids))
    end

    test "regenerates matrix row ids, which are answer keys" do
      survey = insert(:survey)
      row_id = Ecto.UUID.generate()

      question =
        insert(:survey_question,
          survey: survey,
          type: :multi_scale,
          config: %{
            "rows" => [%{"id" => row_id, "text" => "Pace"}],
            "min" => 1,
            "max" => 5,
            "step" => 1
          }
        )

      {:ok, copy} = Surveys.duplicate_question(question)

      assert [%{"id" => copied_row}] = copy.config["rows"]
      refute copied_row == row_id
    end
  end

  describe "reordering" do
    setup do
      survey = insert(:survey)
      {:ok, a} = Surveys.add_question(survey, :scale)
      {:ok, b} = Surveys.add_question(survey, :open_text)
      {:ok, c} = Surveys.add_question(survey, :single_choice)

      %{survey: survey, a: a, b: b, c: c}
    end

    test "applies the given order densely", ctx do
      {:ok, _} = Surveys.reorder_questions(ctx.survey.id, [ctx.c.id, ctx.a.id, ctx.b.id])

      assert ids(ctx.survey.id) == [ctx.c.id, ctx.a.id, ctx.b.id]
      assert positions(ctx.survey.id) == [0, 1, 2]
    end

    test "a question left out of a stale drag keeps its place at the end", ctx do
      # A browser that had not yet seen `c` sends only two ids; `c` must not
      # lose its position.
      {:ok, _} = Surveys.reorder_questions(ctx.survey.id, [ctx.b.id, ctx.a.id])

      assert ids(ctx.survey.id) == [ctx.b.id, ctx.a.id, ctx.c.id]
      assert positions(ctx.survey.id) == [0, 1, 2]
    end

    test "ids from another survey are ignored", ctx do
      stranger = insert(:survey_question, survey: insert(:survey))

      {:ok, _} = Surveys.reorder_questions(ctx.survey.id, [stranger.id, ctx.c.id])

      assert ids(ctx.survey.id) == [ctx.c.id, ctx.a.id, ctx.b.id]
    end

    test "a repeated id does not duplicate a position", ctx do
      {:ok, _} = Surveys.reorder_questions(ctx.survey.id, [ctx.b.id, ctx.b.id, ctx.a.id])

      assert positions(ctx.survey.id) == [0, 1, 2]
      assert ids(ctx.survey.id) == [ctx.b.id, ctx.a.id, ctx.c.id]
    end
  end
end
