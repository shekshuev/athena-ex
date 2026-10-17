defmodule Athena.Surveys.SurveyAnswerTest do
  @moduledoc """
  The projection contract: `value` is the source of truth and
  `value_numeric`/`value_text`/`value_choice_ids` are derived views of it.

  Every type gets a case here, because a projection that silently comes out
  `nil` does not fail - it drops that respondent from the mean, which looks
  like data rather than a bug.
  """
  use Athena.DataCase, async: true

  import Athena.Factory

  alias Athena.Surveys.{QuestionTypes, SurveyAnswer}

  defp project(type, value, config \\ nil) do
    survey = insert(:survey)

    question =
      insert(:survey_question,
        survey: survey,
        type: type,
        config: config || QuestionTypes.default_config(type)
      )

    response = insert(:survey_response, survey: survey)

    changeset =
      SurveyAnswer.changeset(
        %SurveyAnswer{},
        %{response_id: response.id, question_id: question.id, value: value},
        type
      )

    {changeset, question}
  end

  describe "choice projections" do
    test "single choice records the chosen id, and a write-in as text" do
      {config, [first | _]} = choice_config(["Yes, clearly", "Not really"])

      {cs, _q} = project(:single_choice, %{"choice_id" => first}, config)

      assert cs.valid?
      assert get_change(cs, :value_choice_ids) == [first]
      assert get_change(cs, :value_text) == nil

      other = QuestionTypes.other_choice_id()

      {cs, _q} =
        project(
          :single_choice,
          %{"choice_id" => other, "other_text" => "the seminars"},
          config
        )

      assert cs.valid?
      assert get_change(cs, :value_choice_ids) == [other]
      assert get_change(cs, :value_text) == "the seminars"
    end

    test "multiple choice keeps every chosen id" do
      {config, ids} = choice_config(["A", "B", "C"])
      chosen = Enum.take(ids, 2)

      {cs, _q} = project(:multiple_choice, %{"choice_ids" => chosen}, config)

      assert cs.valid?
      assert get_change(cs, :value_choice_ids) == chosen
    end

    test "multiple choice accepts an empty selection as an answered-but-empty row" do
      {config, _ids} = choice_config(["A", "B"])

      {cs, _q} = project(:multiple_choice, %{"choice_ids" => []}, config)

      assert cs.valid?
      assert get_field(cs, :value_choice_ids) == []
    end

    test "a dichotomous answer is numeric as well as categorical" do
      {cs, _q} = project(:dichotomous, %{"choice_id" => "yes"})
      assert cs.valid?
      assert get_change(cs, :value_numeric) == 1.0
      assert get_change(cs, :value_choice_ids) == ["yes"]

      {cs, _q} = project(:dichotomous, %{"choice_id" => "no"})
      assert get_change(cs, :value_numeric) == 0.0
      assert get_change(cs, :value_choice_ids) == ["no"]
    end

    test "a dichotomous answer rejects anything but the reserved ids" do
      {cs, _q} = project(:dichotomous, %{"choice_id" => "maybe"})

      refute cs.valid?
      assert "choice_id: must be yes or no" in errors_on(cs).value
    end

    test "ranking keeps the order, which is what carries the rank" do
      {config, ids} = choice_config(["A", "B", "C"])
      config = Map.put(config, "items", config["options"])
      reversed = Enum.reverse(ids)

      {cs, _q} = project(:ranking, %{"choice_ids" => reversed}, config)

      assert cs.valid?
      assert get_change(cs, :value_choice_ids) == reversed
    end

    test "ranking rejects a repeated item" do
      {config, [first | _]} = choice_config(["A", "B"])
      config = Map.put(config, "items", config["options"])

      {cs, _q} = project(:ranking, %{"choice_ids" => [first, first]}, config)

      refute cs.valid?
      assert "choice_ids: must be distinct ids" in errors_on(cs).value
    end
  end

  describe "numeric and text projections" do
    test "scale, numeric and nps all land in value_numeric as a float" do
      for {type, raw} <- [{:scale, 4}, {:numeric, 7}, {:nps, 10}] do
        {cs, _q} = project(type, %{"number" => raw})

        assert cs.valid?, "#{type}: #{inspect(errors_on(cs))}"
        assert get_change(cs, :value_numeric) === raw / 1
      end
    end

    test "open text lands in value_text, and an empty answer is still an answer" do
      {cs, _q} = project(:open_text, %{"text" => "More practice, less theory."})
      assert cs.valid?
      assert get_change(cs, :value_text) == "More practice, less theory."

      {cs, _q} = project(:open_text, %{"text" => ""})
      assert cs.valid?
      assert get_field(cs, :value_text) == ""
    end

    test "matching keeps the mapping in value with no projection" do
      {cs, _q} = project(:matching, %{"pairs" => %{"left-1" => "right-2"}})

      assert cs.valid?
      assert get_field(cs, :value_numeric) == nil
      assert get_field(cs, :value_choice_ids) == []
    end

    test "a malformed value is rejected rather than projected to nil" do
      for {type, bad} <- [
            {:scale, %{}},
            {:numeric, %{"number" => "four"}},
            {:open_text, %{}},
            {:single_choice, %{}},
            {:matching, %{}},
            {:ranking, %{"choice_ids" => []}}
          ] do
        {cs, _q} = project(type, bad)

        refute cs.valid?, "#{type} accepted #{inspect(bad)}"
      end
    end
  end

  describe "matrix answers" do
    test "row_key is taken from the value, so the row and its index agree" do
      row_id = Ecto.UUID.generate()

      config = %{
        "rows" => [%{"id" => row_id, "text" => "Pace"}],
        "min" => 1,
        "max" => 5,
        "step" => 1
      }

      {cs, _q} = project(:multi_scale, %{"row_id" => row_id, "number" => 3}, config)

      assert cs.valid?
      assert get_change(cs, :row_key) == row_id
      assert get_change(cs, :value_numeric) == 3.0
    end

    test "a matrix answer without a row is rejected" do
      {cs, _q} = project(:multi_scale, %{"number" => 3})

      refute cs.valid?
      assert "row_id: is required for a matrix question" in errors_on(cs).value
    end

    test "every other type keeps row_key empty" do
      for type <- QuestionTypes.all() -- [:multi_scale] do
        {cs, _q} = project(type, %{"number" => 1, "text" => "x", "choice_id" => "yes"})

        assert get_field(cs, :row_key) == ""
      end
    end
  end

  describe "skipping" do
    test "a skip clears the projections but is still a stored row" do
      cs =
        SurveyAnswer.changeset(
          %SurveyAnswer{},
          %{
            response_id: insert(:survey_response).id,
            question_id: insert(:survey_question).id,
            value: %{"number" => 5},
            skipped: true
          },
          :scale
        )

      assert cs.valid?
      assert get_field(cs, :skipped) == true
      assert get_field(cs, :value) == %{}
      assert get_field(cs, :value_numeric) == nil
    end

    test "a skip does not have to carry a well-formed value" do
      cs =
        SurveyAnswer.changeset(
          %SurveyAnswer{},
          %{
            response_id: insert(:survey_response).id,
            question_id: insert(:survey_question).id,
            value: %{},
            skipped: true
          },
          :single_choice
        )

      assert cs.valid?
    end
  end

  describe "uniqueness" do
    test "one answer per question per response" do
      survey = insert(:survey)
      question = insert(:survey_question, survey: survey)
      response = insert(:survey_response, survey: survey)

      attrs = %{response_id: response.id, question_id: question.id, value: %{"number" => 3}}

      assert {:ok, _} =
               %SurveyAnswer{} |> SurveyAnswer.changeset(attrs, :scale) |> Repo.insert()

      assert {:error, changeset} =
               %SurveyAnswer{} |> SurveyAnswer.changeset(attrs, :scale) |> Repo.insert()

      refute changeset.valid?
    end

    test "but a matrix may have one answer per row" do
      survey = insert(:survey)
      row_a = Ecto.UUID.generate()
      row_b = Ecto.UUID.generate()

      question =
        insert(:survey_question,
          survey: survey,
          type: :multi_scale,
          config: %{
            "rows" => [%{"id" => row_a, "text" => "A"}, %{"id" => row_b, "text" => "B"}],
            "min" => 1,
            "max" => 5,
            "step" => 1
          }
        )

      response = insert(:survey_response, survey: survey)

      for {row, value} <- [{row_a, 2}, {row_b, 5}] do
        assert {:ok, _} =
                 %SurveyAnswer{}
                 |> SurveyAnswer.changeset(
                   %{
                     response_id: response.id,
                     question_id: question.id,
                     value: %{"row_id" => row, "number" => value}
                   },
                   :multi_scale
                 )
                 |> Repo.insert()
      end

      assert Repo.aggregate(SurveyAnswer, :count) == 2
    end
  end
end
