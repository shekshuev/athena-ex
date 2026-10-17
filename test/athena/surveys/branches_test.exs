defmodule Athena.Surveys.BranchesTest do
  @moduledoc """
  Branch rules: the shape of a condition, the action/target pairing, and
  ordering - which here is semantics, not presentation, since the first
  matching rule wins.

  Graph-level validity (cycles, forward-only targets, reachability) belongs to
  `Athena.Surveys.Flow` and is tested with it.
  """
  use Athena.DataCase, async: true

  import Athena.Factory

  alias Athena.Surveys
  alias Athena.Surveys.SurveyBranch

  defp survey_with_questions(n, survey_attrs \\ %{}) do
    survey = insert(:survey, Map.new(survey_attrs))

    questions =
      for position <- 0..(n - 1) do
        insert(:survey_question, survey: survey, type: :scale, position: position)
      end

    {survey, questions}
  end

  defp condition(question_id, op, value) do
    %{
      "logic" => "and",
      "clauses" => [%{"question_id" => question_id, "op" => to_string(op), "value" => value}]
    }
  end

  describe "adding" do
    test "a rule hangs off a question and appends last" do
      {survey, [q1, q2 | _]} = survey_with_questions(3)

      {:ok, first} =
        Surveys.add_branch(survey, q1, %{
          "action" => "goto_question",
          "target_question_id" => q2.id,
          "condition" => condition(q1.id, :lte, %{"number" => 2})
        })

      {:ok, second} =
        Surveys.add_branch(survey, q1, %{
          "action" => "end_survey",
          "condition" => condition(q1.id, :gte, %{"number" => 4})
        })

      assert first.position == 0
      assert second.position == 1
      assert Enum.map(Surveys.list_branches_for_question(q1.id), & &1.id) == [first.id, second.id]
    end

    test "a condition needs at least one clause" do
      {survey, [q1 | _]} = survey_with_questions(2)

      assert {:error, changeset} =
               Surveys.add_branch(survey, q1, %{
                 "action" => "end_survey",
                 "condition" => %{"logic" => "and", "clauses" => []}
               })

      refute changeset.valid?
    end

    test "a condition is required outright" do
      {survey, [q1 | _]} = survey_with_questions(2)

      assert {:error, changeset} = Surveys.add_branch(survey, q1, %{"action" => "end_survey"})

      refute changeset.valid?
    end

    test "an all_at_once survey refuses rules, since there is nowhere to branch" do
      {survey, [q1 | _]} =
        survey_with_questions(2, %{
          settings: %Athena.Surveys.SurveySettings{pagination: :all_at_once}
        })

      assert {:error, :all_at_once} =
               Surveys.add_branch(survey, q1, %{
                 "action" => "end_survey",
                 "condition" => condition(q1.id, :lte, %{"number" => 2})
               })
    end
  end

  describe "actions and their targets" do
    setup do
      {survey, questions} = survey_with_questions(3)
      %{survey: survey, questions: questions}
    end

    test "goto_question requires a target question", ctx do
      [q1 | _] = ctx.questions

      assert {:error, changeset} =
               Surveys.add_branch(ctx.survey, q1, %{
                 "action" => "goto_question",
                 "condition" => condition(q1.id, :eq, %{"number" => 1})
               })

      assert "can't be blank" in errors_on(changeset).target_question_id
    end

    test "goto_page requires a target page", ctx do
      [q1 | _] = ctx.questions

      assert {:error, changeset} =
               Surveys.add_branch(ctx.survey, q1, %{
                 "action" => "goto_page",
                 "condition" => condition(q1.id, :eq, %{"number" => 1})
               })

      assert "can't be blank" in errors_on(changeset).target_page
    end

    test "switching the action clears the target the old one used", ctx do
      [q1, q2 | _] = ctx.questions

      {:ok, branch} =
        Surveys.add_branch(ctx.survey, q1, %{
          "action" => "goto_question",
          "target_question_id" => q2.id,
          "condition" => condition(q1.id, :eq, %{"number" => 1})
        })

      {:ok, switched} =
        Surveys.update_branch(branch, %{"action" => "goto_page", "target_page" => 1})

      # A stale target_question_id would be read by nothing and would mislead
      # the next person to open the rule.
      assert switched.target_question_id == nil
      assert switched.target_page == 1

      {:ok, ended} = Surveys.update_branch(switched, %{"action" => "end_survey"})

      assert ended.target_page == nil
      assert ended.target_question_id == nil
    end
  end

  describe "operators" do
    test "the presence operators take no operand" do
      {survey, [q1 | _]} = survey_with_questions(2)

      for op <- [:answered, :not_answered] do
        {:ok, branch} =
          Surveys.add_branch(survey, q1, %{
            "action" => "end_survey",
            "condition" => condition(q1.id, op, %{})
          })

        assert [clause] = branch.condition.clauses
        assert clause.op == op
        assert clause.value == %{}
      end
    end

    test "every other operator requires an operand" do
      {survey, [q1 | _]} = survey_with_questions(2)

      operators = Athena.Surveys.BranchClause.operators() -- [:answered, :not_answered]

      for op <- operators do
        assert {:error, changeset} =
                 Surveys.add_branch(survey, q1, %{
                   "action" => "end_survey",
                   "condition" => condition(q1.id, op, %{})
                 })

        refute changeset.valid?, "#{op} accepted an empty value"
      end
    end

    test "an unknown operator is refused" do
      {survey, [q1 | _]} = survey_with_questions(2)

      assert {:error, changeset} =
               Surveys.add_branch(survey, q1, %{
                 "action" => "end_survey",
                 "condition" => condition(q1.id, :approximately, %{"number" => 3})
               })

      refute changeset.valid?
    end
  end

  describe "ordering" do
    setup do
      {survey, [q1 | _] = questions} = survey_with_questions(2)

      rules =
        for n <- 1..3 do
          {:ok, rule} =
            Surveys.add_branch(survey, q1, %{
              "action" => "end_survey",
              "condition" => condition(q1.id, :eq, %{"number" => n})
            })

          rule
        end

      %{survey: survey, questions: questions, q1: q1, rules: rules}
    end

    test "reordering decides which rule wins", ctx do
      [a, b, c] = ctx.rules

      {:ok, _} = Surveys.reorder_branches(ctx.q1.id, [c.id, a.id, b.id])

      assert Enum.map(Surveys.list_branches_for_question(ctx.q1.id), & &1.id) == [
               c.id,
               a.id,
               b.id
             ]
    end

    test "deleting a rule closes the gap", ctx do
      [_a, b, _c] = ctx.rules

      {:ok, _} = Surveys.delete_branch(b)

      assert Enum.map(Surveys.list_branches_for_question(ctx.q1.id), & &1.position) == [0, 1]
    end

    test "rules are grouped by question for the logic editor", ctx do
      grouped = Surveys.branches_by_question(ctx.survey.id)

      assert map_size(grouped) == 1
      assert length(grouped[ctx.q1.id]) == 3
    end

    test "any_branches?/1 reports whether a survey branches at all", ctx do
      assert Surveys.any_branches?(ctx.survey)

      Enum.each(ctx.rules, &Surveys.delete_branch/1)

      refute Surveys.any_branches?(ctx.survey)
    end
  end

  describe "cascades" do
    test "deleting the survey takes its rules" do
      {survey, [q1 | _]} = survey_with_questions(2)

      {:ok, _} =
        Surveys.add_branch(survey, q1, %{
          "action" => "end_survey",
          "condition" => condition(q1.id, :lte, %{"number" => 2})
        })

      {:ok, _} = Surveys.delete_survey(survey)

      assert Repo.aggregate(SurveyBranch, :count) == 0
    end
  end
end
