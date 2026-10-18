defmodule Athena.Surveys.AnswerParamsTest do
  @moduledoc """
  The bridge between browser form params and the typed answer `value` map.

  Tested as a table, and paired with a round-trip through
  `SurveyAnswer.changeset/3`: the point of this module is that what the forms
  post is exactly what the changeset accepts, so checking the cast in
  isolation would miss the only failure that matters.
  """
  use Athena.DataCase, async: true

  import Athena.Factory

  alias Athena.Surveys.{AnswerParams, QuestionTypes, SurveyAnswer}

  describe "cast/2" do
    test "unwraps the \"value\" key the rendered forms nest under" do
      assert AnswerParams.cast(:scale, %{"value" => %{"number" => "3"}}) == %{"number" => 3}
      assert AnswerParams.cast(:scale, %{"number" => "3"}) == %{"number" => 3}
    end

    test "parses numbers out of strings" do
      assert AnswerParams.cast(:scale, %{"number" => "4"}) == %{"number" => 4}
      assert AnswerParams.cast(:numeric, %{"number" => "4.5"}) == %{"number" => 4.5}
      assert AnswerParams.cast(:numeric, %{"number" => " 7 "}) == %{"number" => 7}
      assert AnswerParams.cast(:nps, %{"number" => "10"}) == %{"number" => 10}
    end

    test "leaves unparseable input out rather than coercing it" do
      # "4 apples" is a question to ask the respondent, not a 4. Dropping the
      # key lets the changeset report it.
      for bad <- ["", "4 apples", "abc", "--3"] do
        assert AnswerParams.cast(:numeric, %{"number" => bad}) == %{},
               "coerced #{inspect(bad)}"
      end
    end

    test "drops the blank hidden input a checkbox group needs" do
      assert AnswerParams.cast(:multiple_choice, %{"choice_ids" => ["", "a", "b"]}) ==
               %{"choice_ids" => ["a", "b"]}

      # Everything unchecked: an answered-but-empty row, not a missing one.
      assert AnswerParams.cast(:multiple_choice, %{"choice_ids" => [""]}) ==
               %{"choice_ids" => []}

      assert AnswerParams.cast(:multiple_choice, %{}) == %{"choice_ids" => []}
    end

    test "keeps an empty open-text answer, which is a real answer" do
      assert AnswerParams.cast(:open_text, %{"text" => ""}) == %{"text" => ""}
      assert AnswerParams.cast(:open_text, %{}) == %{}
    end

    test "omits a blank write-in rather than storing an empty string" do
      assert AnswerParams.cast(:single_choice, %{"choice_id" => "a", "other_text" => ""}) ==
               %{"choice_id" => "a"}

      assert AnswerParams.cast(:single_choice, %{"choice_id" => "other", "other_text" => "x"}) ==
               %{"choice_id" => "other", "other_text" => "x"}
    end

    test "carries a matrix row through alongside its value" do
      row = Ecto.UUID.generate()

      assert AnswerParams.cast(:multi_scale, %{"row_id" => row, "number" => "2"}) ==
               %{"row_id" => row, "number" => 2}
    end

    test "drops matching pairs left unchosen" do
      assert AnswerParams.cast(:matching, %{"pairs" => %{"l1" => "r2", "l2" => ""}}) ==
               %{"pairs" => %{"l1" => "r2"}}

      assert AnswerParams.cast(:matching, %{}) == %{"pairs" => %{}}
    end

    test "preserves ranking order, which is what carries the rank" do
      assert AnswerParams.cast(:ranking, %{"choice_ids" => ["c", "a", "b"]}) ==
               %{"choice_ids" => ["c", "a", "b"]}
    end

    test "non-map params yield an empty value" do
      assert AnswerParams.cast(:scale, "nonsense") == %{}
    end
  end

  describe "what the forms post is what the changeset accepts" do
    setup do
      survey = insert(:survey)
      %{survey: survey, response: insert(:survey_response, survey: survey)}
    end

    test "every type round-trips from form shape to a valid answer", ctx do
      choice_a = Ecto.UUID.generate()
      choice_b = Ecto.UUID.generate()
      row = Ecto.UUID.generate()

      # Keyed exactly as `AthenaWeb.SurveyComponents` names its inputs.
      posted = %{
        single_choice: %{"choice_id" => choice_a},
        multiple_choice: %{"choice_ids" => ["", choice_a, choice_b]},
        dichotomous: %{"choice_id" => "yes"},
        open_text: %{"text" => "More practice"},
        numeric: %{"number" => "12"},
        scale: %{"number" => "4"},
        multi_scale: %{"row_id" => row, "number" => "5"},
        matching: %{"pairs" => %{"l1" => "r1"}},
        ranking: %{"choice_ids" => [choice_b, choice_a]},
        nps: %{"number" => "9"}
      }

      for type <- QuestionTypes.all() do
        params = Map.fetch!(posted, type)

        question =
          insert(:survey_question, survey: ctx.survey, type: type, config: config(type, row))

        changeset =
          SurveyAnswer.changeset(
            %SurveyAnswer{},
            %{
              response_id: ctx.response.id,
              question_id: question.id,
              value: AnswerParams.cast(type, %{"value" => params})
            },
            type
          )

        assert changeset.valid?,
               "#{type} posted #{inspect(params)} and the changeset rejected it: #{inspect(errors_on(changeset))}"
      end
    end

    test "a number field holding prose is rejected, not silently zeroed", ctx do
      question = insert(:survey_question, survey: ctx.survey, type: :scale)

      changeset =
        SurveyAnswer.changeset(
          %SurveyAnswer{},
          %{
            response_id: ctx.response.id,
            question_id: question.id,
            value: AnswerParams.cast(:scale, %{"value" => %{"number" => "quite good"}})
          },
          :scale
        )

      refute changeset.valid?
    end
  end

  defp config(:multi_scale, row),
    do: %{"rows" => [%{"id" => row, "text" => "Pace"}], "min" => 1, "max" => 5, "step" => 1}

  defp config(type, _row), do: QuestionTypes.default_config(type)
end
