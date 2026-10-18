defmodule Athena.Surveys.FlowTest do
  @moduledoc """
  The branching engine. Built in memory rather than through the database
  wherever possible - `Flow` is pure, and testing it that way is what proves
  the builder's preview can run it with no writes.
  """
  use ExUnit.Case, async: true

  alias Athena.Surveys.{
    BranchClause,
    BranchCondition,
    Flow,
    Survey,
    SurveyAnswer,
    SurveyBranch,
    SurveyQuestion,
    SurveySettings
  }

  # -- builders -------------------------------------------------------------

  defp survey(settings) do
    %Survey{
      id: Ecto.UUID.generate(),
      title: "Feedback",
      status: :published,
      settings: struct(%SurveySettings{}, settings)
    }
  end

  defp question(position, opts \\ []) do
    %SurveyQuestion{
      id: Keyword.get_lazy(opts, :id, &Ecto.UUID.generate/0),
      position: position,
      page: Keyword.get(opts, :page, 0),
      type: Keyword.get(opts, :type, :scale),
      body: %{},
      required: false,
      config: %{}
    }
  end

  defp branch(question, opts) do
    %SurveyBranch{
      id: Ecto.UUID.generate(),
      question_id: question.id,
      position: Keyword.get(opts, :position, 0),
      action: Keyword.fetch!(opts, :action),
      target_question_id: opts |> Keyword.get(:target) |> id_of(),
      target_page: Keyword.get(opts, :target_page),
      condition: %BranchCondition{
        logic: Keyword.get(opts, :logic, :and),
        clauses: Keyword.get(opts, :clauses, [clause(question, :answered, %{})])
      }
    }
  end

  defp id_of(nil), do: nil
  defp id_of(%SurveyQuestion{id: id}), do: id
  defp id_of(id) when is_binary(id), do: id

  defp clause(question, op, value) do
    %BranchClause{question_id: id_of(question), op: op, value: value}
  end

  defp answers(pairs) do
    Map.new(pairs, fn
      {question, value} when is_number(value) ->
        {{id_of(question), ""}, %SurveyAnswer{value_numeric: value / 1, skipped: false}}

      {question, {:choices, ids}} ->
        {{id_of(question), ""}, %SurveyAnswer{value_choice_ids: ids, skipped: false}}

      {question, {:text, text}} ->
        {{id_of(question), ""}, %SurveyAnswer{value_text: text, skipped: false}}

      {question, {:row, row, value}} ->
        {{id_of(question), row}, %SurveyAnswer{value_numeric: value / 1, skipped: false}}

      {question, :skipped} ->
        {{id_of(question), ""}, %SurveyAnswer{skipped: true}}
    end)
  end

  defp flow(questions, branches \\ [], settings \\ %{}) do
    Flow.build(survey(settings), questions, branches)
  end

  # -- linear walking -------------------------------------------------------

  describe "a survey with no rules" do
    test "is a plain linear walk needing no special case" do
      [q0, q1, q2] = questions = Enum.map(0..2, &question(&1))
      flow = flow(questions)

      assert Flow.first_question(flow).id == q0.id
      assert {:question, next} = Flow.next_question(flow, q0, %{})
      assert next.id == q1.id
      assert {:question, last} = Flow.next_question(flow, q1, %{})
      assert last.id == q2.id
      assert Flow.next_question(flow, q2, %{}) == :end
    end

    test "an empty survey has no first question" do
      assert Flow.first_question(flow([])) == nil
      assert Flow.visible_questions(flow([])) == []
    end

    test "questions arriving out of order are sorted, not trusted" do
      q0 = question(0)
      q1 = question(1)

      flow = flow([q1, q0])

      assert Flow.first_question(flow).id == q0.id
    end
  end

  # -- operators ------------------------------------------------------------

  describe "operators" do
    setup do
      gate = question(0)
      target = question(2)
      %{gate: gate, target: target, questions: [gate, question(1), target]}
    end

    test "numeric comparisons route on the answer's value", ctx do
      table = [
        {:lte, %{"number" => 2}, 1, true},
        {:lte, %{"number" => 2}, 2, true},
        {:lte, %{"number" => 2}, 3, false},
        {:lt, %{"number" => 2}, 2, false},
        {:gte, %{"number" => 4}, 4, true},
        {:gt, %{"number" => 4}, 4, false},
        {:eq, %{"number" => 3}, 3, true},
        {:eq, %{"number" => 3}, 4, false},
        {:neq, %{"number" => 3}, 4, true},
        {:neq, %{"number" => 3}, 3, false},
        {:between, %{"from" => 2, "to" => 4}, 2, true},
        {:between, %{"from" => 2, "to" => 4}, 4, true},
        {:between, %{"from" => 2, "to" => 4}, 5, false}
      ]

      for {op, operand, given, should_match} <- table do
        rule = branch(ctx.gate, action: :end_survey, clauses: [clause(ctx.gate, op, operand)])
        f = flow(ctx.questions, [rule])
        step = Flow.next_question(f, ctx.gate, answers([{ctx.gate, given}]))

        if should_match do
          assert step == :end, "#{op} #{inspect(operand)} should have matched #{given}"
        else
          assert match?({:question, _}, step),
                 "#{op} #{inspect(operand)} should not have matched #{given}"
        end
      end
    end

    test "choice operators compare sets", ctx do
      [a, b, c] = Enum.map(1..3, fn _ -> Ecto.UUID.generate() end)

      table = [
        {:eq, %{"choice_ids" => [a]}, [a], true},
        {:eq, %{"choice_ids" => [a]}, [a, b], false},
        {:eq, %{"choice_ids" => [a, b]}, [b, a], true},
        {:in, %{"choice_ids" => [a, b]}, [b], true},
        {:in, %{"choice_ids" => [a, b]}, [c], false},
        {:not_in, %{"choice_ids" => [a, b]}, [c], true},
        {:contains_any, %{"choice_ids" => [a, c]}, [b, c], true},
        {:contains_any, %{"choice_ids" => [a]}, [b, c], false},
        {:contains_all, %{"choice_ids" => [a, b]}, [a, b, c], true},
        {:contains_all, %{"choice_ids" => [a, b]}, [a, c], false}
      ]

      for {op, operand, chosen, should_match} <- table do
        rule = branch(ctx.gate, action: :end_survey, clauses: [clause(ctx.gate, op, operand)])
        f = flow(ctx.questions, [rule])
        step = Flow.next_question(f, ctx.gate, answers([{ctx.gate, {:choices, chosen}}]))

        if should_match do
          assert step == :end, "#{op} #{inspect(operand)} should have matched #{inspect(chosen)}"
        else
          refute step == :end,
                 "#{op} #{inspect(operand)} should not have matched #{inspect(chosen)}"
        end
      end
    end

    test "text operators compare the text projection" do
      gate = question(0, type: :open_text)
      questions = [gate, question(1), question(2)]

      for {op, operand, given, should_match} <- [
            {:eq, %{"text" => "yes"}, "yes", true},
            {:eq, %{"text" => "yes"}, "no", false},
            {:neq, %{"text" => "yes"}, "no", true},
            {:in, %{"texts" => ["yes", "sure"]}, "sure", true},
            {:in, %{"texts" => ["yes"]}, "no", false}
          ] do
        rule = branch(gate, action: :end_survey, clauses: [clause(gate, op, operand)])
        f = flow(questions, [rule])
        step = Flow.next_question(f, gate, answers([{gate, {:text, given}}]))

        assert step == :end == should_match, "#{op} #{inspect(operand)} on #{given}"
      end
    end

    test "presence operators treat a deliberate skip as not answered", ctx do
      answered =
        branch(ctx.gate, action: :end_survey, clauses: [clause(ctx.gate, :answered, %{})])

      f = flow(ctx.questions, [answered])

      assert Flow.next_question(f, ctx.gate, answers([{ctx.gate, 3}])) == :end
      refute Flow.next_question(f, ctx.gate, answers([{ctx.gate, :skipped}])) == :end
      refute Flow.next_question(f, ctx.gate, %{}) == :end

      missing =
        branch(ctx.gate, action: :end_survey, clauses: [clause(ctx.gate, :not_answered, %{})])

      f = flow(ctx.questions, [missing])

      assert Flow.next_question(f, ctx.gate, %{}) == :end
      assert Flow.next_question(f, ctx.gate, answers([{ctx.gate, :skipped}])) == :end
      refute Flow.next_question(f, ctx.gate, answers([{ctx.gate, 3}])) == :end
    end

    test "an incomparable operand is false for both :eq and :neq", ctx do
      # A numeric rule pointed at a text answer is a misconfiguration. It must
      # not reroute everyone, and :neq must not be "true by negation".
      for op <- [:eq, :neq] do
        rule =
          branch(ctx.gate, action: :end_survey, clauses: [clause(ctx.gate, op, %{"number" => 3})])

        f = flow(ctx.questions, [rule])

        refute Flow.next_question(f, ctx.gate, answers([{ctx.gate, {:text, "three"}}])) == :end,
               "#{op} matched an incomparable answer"
      end
    end

    test "a malformed operand never matches", ctx do
      for operand <- [%{}, %{"number" => "three"}, %{"choice_ids" => "not-a-list"}] do
        rule =
          branch(ctx.gate, action: :end_survey, clauses: [clause(ctx.gate, :eq, operand)])

        f = flow(ctx.questions, [rule])

        refute Flow.next_question(f, ctx.gate, answers([{ctx.gate, 3}])) == :end
      end
    end
  end

  describe "and / or" do
    test "and needs every clause, or needs one" do
      a = question(0)
      b = question(1)
      questions = [a, b, question(2)]

      clauses = [clause(a, :gte, %{"number" => 4}), clause(b, :gte, %{"number" => 4})]

      both = flow(questions, [branch(b, action: :end_survey, logic: :and, clauses: clauses)])
      either = flow(questions, [branch(b, action: :end_survey, logic: :or, clauses: clauses)])

      high = answers([{a, 5}, {b, 5}])
      mixed = answers([{a, 5}, {b, 1}])
      low = answers([{a, 1}, {b, 1}])

      assert Flow.next_question(both, b, high) == :end
      refute Flow.next_question(both, b, mixed) == :end

      assert Flow.next_question(either, b, high) == :end
      assert Flow.next_question(either, b, mixed) == :end
      refute Flow.next_question(either, b, low) == :end
    end

    test "a condition with no clauses never matches" do
      q = question(0)
      flow = flow([q, question(1)], [branch(q, action: :end_survey, clauses: [])])

      refute Flow.next_question(flow, q, answers([{q, 3}])) == :end
    end
  end

  # -- actions --------------------------------------------------------------

  describe "actions" do
    setup do
      questions = Enum.map(0..3, &question(&1))
      %{questions: questions, q: questions}
    end

    test "goto_question jumps forward", ctx do
      [q0, _q1, q2, _q3] = ctx.questions
      rule = branch(q0, action: :goto_question, target: q2)

      assert {:question, landed} =
               Flow.next_question(flow(ctx.questions, [rule]), q0, answers([{q0, 1}]))

      assert landed.id == q2.id
    end

    test "end_survey finishes early", ctx do
      [q0 | _] = ctx.questions
      rule = branch(q0, action: :end_survey)

      assert Flow.next_question(flow(ctx.questions, [rule]), q0, answers([{q0, 1}])) == :end
    end

    test "skip_question skips the one that would have come next, not the current", ctx do
      [q0, _q1, q2, _q3] = ctx.questions
      rule = branch(q0, action: :skip_question)

      assert {:question, landed} =
               Flow.next_question(flow(ctx.questions, [rule]), q0, answers([{q0, 1}]))

      assert landed.id == q2.id
    end

    test "skip_question at the end finishes", ctx do
      [_, _, q2, _] = ctx.questions
      rule = branch(q2, action: :skip_question)

      assert Flow.next_question(flow(ctx.questions, [rule]), q2, answers([{q2, 1}])) == :end
    end

    test "goto_page lands on the first question of that page" do
      q0 = question(0, page: 0)
      q1 = question(1, page: 0)
      q2 = question(2, page: 1)
      q3 = question(3, page: 1)
      rule = branch(q0, action: :goto_page, target_page: 1)

      assert {:question, landed} =
               Flow.next_question(flow([q0, q1, q2, q3], [rule]), q0, answers([{q0, 1}]))

      assert landed.id == q2.id
    end

    test "a jump to a deleted question falls through instead of stranding anyone", ctx do
      [q0, q1 | _] = ctx.questions
      rule = branch(q0, action: :goto_question, target: Ecto.UUID.generate())

      assert {:question, landed} =
               Flow.next_question(flow(ctx.questions, [rule]), q0, answers([{q0, 1}]))

      assert landed.id == q1.id
    end

    test "a jump to an empty page falls through too", ctx do
      [q0, q1 | _] = ctx.questions
      rule = branch(q0, action: :goto_page, target_page: 9)

      assert {:question, landed} =
               Flow.next_question(flow(ctx.questions, [rule]), q0, answers([{q0, 1}]))

      assert landed.id == q1.id
    end

    test "the first matching rule wins, in position order", ctx do
      [q0, _q1, q2, q3] = ctx.questions

      specific =
        branch(q0,
          position: 0,
          action: :goto_question,
          target: q3,
          clauses: [clause(q0, :eq, %{"number" => 1})]
        )

      general = branch(q0, position: 1, action: :goto_question, target: q2)

      flow = flow(ctx.questions, [general, specific])

      assert {:question, landed} = Flow.next_question(flow, q0, answers([{q0, 1}]))
      assert landed.id == q3.id, "the specific rule should have won"

      assert {:question, landed} = Flow.next_question(flow, q0, answers([{q0, 5}]))
      assert landed.id == q2.id, "the general rule should catch the rest"
    end

    test "an unknown current question ends rather than crashing", ctx do
      assert Flow.next_question(flow(ctx.questions), Ecto.UUID.generate(), %{}) == :end
    end
  end

  # -- matrix questions -----------------------------------------------------

  describe "matrix questions in conditions" do
    test "a clause names the row it tests" do
      row_a = Ecto.UUID.generate()
      row_b = Ecto.UUID.generate()
      matrix = question(0, type: :multi_scale)
      questions = [matrix, question(1), question(2)]

      rule =
        branch(matrix,
          action: :end_survey,
          clauses: [clause(matrix, :lte, %{"number" => 2, "row_id" => row_a})]
        )

      flow = flow(questions, [rule])

      assert Flow.next_question(flow, matrix, answers([{matrix, {:row, row_a, 1}}])) == :end

      # The rule is about row A; a low score on row B must not trigger it.
      refute Flow.next_question(flow, matrix, answers([{matrix, {:row, row_b, 1}}])) == :end
    end

    test "a clause with no row cannot be evaluated and is false" do
      row = Ecto.UUID.generate()
      matrix = question(0, type: :multi_scale)
      questions = [matrix, question(1)]

      rule =
        branch(matrix, action: :end_survey, clauses: [clause(matrix, :lte, %{"number" => 2})])

      flow = flow(questions, [rule])

      refute Flow.next_question(flow, matrix, answers([{matrix, {:row, row, 1}}])) == :end
    end
  end

  # -- back navigation -----------------------------------------------------

  describe "previous/2" do
    test "pops the path actually taken, not position arithmetic" do
      [q0, _q1, _q2] = questions = Enum.map(0..2, &question(&1))
      flow = flow(questions)

      # The respondent jumped q0 -> q2, so "back" is q0, not q1.
      assert {:question, back, rest} = Flow.previous(flow, [q0.id])
      assert back.id == q0.id
      assert rest == []

      assert Flow.previous(flow, []) == :none
    end

    test "skips ids whose questions were deleted" do
      [q0, _q1] = questions = Enum.map(0..1, &question(&1))
      flow = flow(questions)

      assert {:question, back, rest} = Flow.previous(flow, [Ecto.UUID.generate(), q0.id])
      assert back.id == q0.id
      assert rest == []
    end

    test "a survey that disallows going back says so, so the player cannot forget" do
      [q0, _q1] = questions = Enum.map(0..1, &question(&1))
      flow = flow(questions, [], %{allow_back: false})

      assert Flow.previous(flow, [q0.id]) == :none
    end
  end

  # -- visible questions ---------------------------------------------------

  describe "visible_questions/2" do
    test "counts the path taken, not the whole survey" do
      [q0, q1, q2, q3] = questions = Enum.map(0..3, &question(&1))

      rule =
        branch(q0,
          action: :goto_question,
          target: q3,
          clauses: [clause(q0, :lte, %{"number" => 2})]
        )

      flow = flow(questions, [rule])

      short = Flow.visible_questions(flow, answers([{q0, 1}]))
      assert Enum.map(short, & &1.id) == [q0.id, q3.id]

      long = Flow.visible_questions(flow, answers([{q0, 5}]))
      assert Enum.map(long, & &1.id) == [q0.id, q1.id, q2.id, q3.id]
    end

    test "with no answers it walks the fall-through path" do
      questions = Enum.map(0..2, &question(&1))

      assert length(Flow.visible_questions(flow(questions))) == 3
    end

    test "an early end truncates the path" do
      [q0, _q1, _q2] = questions = Enum.map(0..2, &question(&1))
      rule = branch(q0, action: :end_survey)

      visible = Flow.visible_questions(flow(questions, [rule]), answers([{q0, 1}]))

      assert Enum.map(visible, & &1.id) == [q0.id]
    end

    test "terminates on a looping survey instead of hanging the player" do
      [q0, q1] = questions = Enum.map(0..1, &question(&1))
      loop = branch(q1, action: :goto_question, target: q0)

      visible = Flow.visible_questions(flow(questions, [loop]), answers([{q0, 1}, {q1, 1}]))

      assert Enum.map(visible, & &1.id) == [q0.id, q1.id]
    end
  end

  # -- pages ---------------------------------------------------------------

  describe "page stepping" do
    setup do
      q0 = question(0, page: 0)
      q1 = question(1, page: 0)
      q2 = question(2, page: 1)
      q3 = question(3, page: 2)

      %{questions: [q0, q1, q2, q3], q0: q0, q1: q1, q2: q2, q3: q3}
    end

    test "walks pages in order", ctx do
      flow = flow(ctx.questions)

      assert Flow.pages(flow) == [0, 1, 2]
      assert Flow.next_page(flow, 0, %{}) == {:page, 1}
      assert Flow.next_page(flow, 1, %{}) == {:page, 2}
      assert Flow.next_page(flow, 2, %{}) == :end
    end

    test "a rule on any question of the page may redirect it", ctx do
      # The rule hangs off the page's *second* question - a page is answered
      # as a whole, so it is as entitled to redirect as the first.
      rule =
        branch(ctx.q1,
          action: :goto_page,
          target_page: 2,
          clauses: [clause(ctx.q1, :gte, %{"number" => 4})]
        )

      flow = flow(ctx.questions, [rule])

      assert Flow.next_page(flow, 0, answers([{ctx.q1, 5}])) == {:page, 2}
      assert Flow.next_page(flow, 0, answers([{ctx.q1, 1}])) == {:page, 1}
    end

    test "end_survey on a page ends the survey", ctx do
      rule = branch(ctx.q0, action: :end_survey)
      flow = flow(ctx.questions, [rule])

      assert Flow.next_page(flow, 0, answers([{ctx.q0, 1}])) == :end
    end

    test "questions_on_page/2 returns them in order", ctx do
      flow = flow(ctx.questions)

      assert Enum.map(Flow.questions_on_page(flow, 0), & &1.id) == [ctx.q0.id, ctx.q1.id]
      assert Flow.questions_on_page(flow, 9) == []
    end
  end

  # -- graph validation ----------------------------------------------------

  describe "validate_graph/1" do
    test "sound logic produces no issues" do
      [q0, _q1, q2] = questions = Enum.map(0..2, &question(&1))
      rule = branch(q0, action: :goto_question, target: q2)

      assert Flow.validate_graph(flow(questions, [rule])) == []
    end

    test "a linear survey with no rules is sound" do
      assert Flow.validate_graph(flow(Enum.map(0..2, &question(&1)))) == []
    end

    test "catches a jump to the rule's own question" do
      [q0, _q1] = questions = Enum.map(0..1, &question(&1))
      rule = branch(q0, action: :goto_question, target: q0)

      issues = Flow.validate_graph(flow(questions, [rule]))

      assert Enum.any?(issues, &(&1.issue == :self_target))
    end

    test "catches a backward jump, which lets a respondent loop" do
      [q0, q1] = questions = Enum.map(0..1, &question(&1))
      rule = branch(q1, action: :goto_question, target: q0)

      issues = Flow.validate_graph(flow(questions, [rule]))

      assert Enum.any?(issues, &(&1.issue == :backward_target))
      assert Enum.any?(issues, &(&1.issue == :cycle))
    end

    test "catches a loop closed through a page jump" do
      q0 = question(0, page: 0)
      q1 = question(1, page: 1)
      rule = branch(q1, action: :goto_page, target_page: 0)

      issues = Flow.validate_graph(flow([q0, q1], [rule]))

      assert Enum.any?(issues, &(&1.issue == :cycle))
    end

    test "catches a jump to a question or page that no longer exists" do
      [q0, _q1] = questions = Enum.map(0..1, &question(&1))

      dangling = branch(q0, action: :goto_question, target: Ecto.UUID.generate())
      assert [%{issue: :dangling_target}] = Flow.validate_graph(flow(questions, [dangling]))

      page = branch(q0, action: :goto_page, target_page: 7)

      assert [%{issue: :dangling_page, target_page: 7}] =
               Flow.validate_graph(flow(questions, [page]))
    end

    test "catches a clause testing an answer not given yet" do
      [q0, q1] = questions = Enum.map(0..1, &question(&1))

      # A rule on q0 cannot test q1 - the respondent has not reached it.
      rule = branch(q0, action: :end_survey, clauses: [clause(q1, :gte, %{"number" => 4})])

      issues = Flow.validate_graph(flow(questions, [rule]))

      assert Enum.any?(issues, &(&1.issue == :forward_clause))
    end

    test "catches a clause testing a question from another survey" do
      [q0, _q1] = questions = Enum.map(0..1, &question(&1))
      stranger = Ecto.UUID.generate()

      rule =
        branch(q0, action: :end_survey, clauses: [clause(stranger, :gte, %{"number" => 4})])

      assert [%{issue: :dangling_clause, clause_question_id: ^stranger}] =
               Flow.validate_graph(flow(questions, [rule]))
    end

    test "catches a matrix clause that does not say which row" do
      matrix = question(0, type: :multi_scale)
      questions = [matrix, question(1)]

      rule =
        branch(matrix, action: :end_survey, clauses: [clause(matrix, :lte, %{"number" => 2})])

      assert [%{issue: :matrix_clause_without_row}] = Flow.validate_graph(flow(questions, [rule]))

      with_row =
        branch(matrix,
          action: :end_survey,
          clauses: [clause(matrix, :lte, %{"number" => 2, "row_id" => Ecto.UUID.generate()})]
        )

      assert Flow.validate_graph(flow(questions, [with_row])) == []
    end

    test "catches rules on a survey that shows everything at once" do
      [q0, _q1] = questions = Enum.map(0..1, &question(&1))
      rule = branch(q0, action: :end_survey)

      issues = Flow.validate_graph(flow(questions, [rule], %{pagination: :all_at_once}))

      assert Enum.any?(issues, &(&1.issue == :all_at_once_with_rules))
    end

    test "all_at_once without rules is fine" do
      questions = Enum.map(0..1, &question(&1))

      assert Flow.validate_graph(flow(questions, [], %{pagination: :all_at_once})) == []
    end

    test "issues carry ids, not prose, so the UI owns the wording" do
      [q0, q1] = questions = Enum.map(0..1, &question(&1))
      rule = branch(q1, action: :goto_question, target: q0)

      [issue | _] = Flow.validate_graph(flow(questions, [rule]))

      assert is_atom(issue.issue)
      assert Map.has_key?(issue, :question_id)
      refute Enum.any?(Map.values(issue), &(is_binary(&1) and String.contains?(&1, " ")))
    end
  end
end
