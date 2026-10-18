defmodule Athena.Surveys.ResultsTest do
  @moduledoc """
  Reading answers back. The maths is already pinned in `Stats`, so these tests
  are about the reading: that the right rows are gathered, that missing and
  refused are told apart, that a question's own option order survives, and
  that identity is hidden exactly where it should be.
  """
  use Athena.DataCase, async: true

  import Athena.Factory

  alias Athena.Surveys
  alias Athena.Surveys.Results

  defp survey_with(types) do
    survey = insert(:survey, status: :published)

    questions =
      for {type, position} <- Enum.with_index(types) do
        {:ok, question} = Surveys.add_question(survey, type, %{"position" => position})
        question
      end

    {survey, questions}
  end

  defp respond(survey, answers, opts \\ []) do
    student = insert(:account)

    response =
      insert(:survey_response,
        survey: survey,
        account_id: student.id,
        cohort_id: Keyword.get(opts, :cohort_id),
        status: Keyword.get(opts, :status, :completed)
      )

    for {question, value} <- answers do
      case value do
        :skip -> {:ok, _} = Surveys.skip_answer(response, question)
        _ -> {:ok, _} = Surveys.save_answer(response, question, value)
      end
    end

    response
  end

  defp scale(n), do: %{"number" => n}

  describe "summary/1" do
    test "counts each status and the completion rate" do
      {survey, [q]} = survey_with([:scale])

      respond(survey, [{q, scale(4)}], status: :completed)
      respond(survey, [{q, scale(3)}], status: :completed)
      respond(survey, [{q, scale(2)}], status: :in_progress)
      respond(survey, [], status: :abandoned)

      summary = Results.summary(survey.id)

      assert summary.started == 4
      assert summary.completed == 2
      assert summary.in_progress == 1
      assert summary.abandoned == 1
      assert summary.completion_rate == 0.5
    end

    test "separates cohort responses from identified ones" do
      {survey, [q]} = survey_with([:scale])
      cohort = insert(:cohort)

      respond(survey, [{q, scale(4)}], cohort_id: cohort.id)
      respond(survey, [{q, scale(4)}], cohort_id: cohort.id)
      respond(survey, [{q, scale(2)}])

      summary = Results.summary(survey.id)

      assert summary.cohort_count == 1
      assert summary.identified_count == 1
    end

    test "an untouched survey has no completion rate rather than zero" do
      {survey, _questions} = survey_with([:scale])

      assert Results.summary(survey.id).completion_rate == nil
    end
  end

  describe "completion_funnel/1" do
    test "shows where people stopped, and tells refusal from never reaching" do
      {survey, [q1, q2, q3]} = survey_with([:scale, :scale, :open_text])

      respond(survey, [{q1, scale(4)}, {q2, scale(3)}, {q3, %{"text" => "fine"}}])
      respond(survey, [{q1, scale(5)}, {q2, scale(2)}])
      respond(survey, [{q1, scale(1)}, {q2, :skip}])
      respond(survey, [{q1, scale(3)}])

      [first, second, third] = Results.completion_funnel(survey.id)

      assert first.question.id == q1.id
      assert first.answered == 4
      assert first.not_reached == 0

      assert second.answered == 2
      # One person saw it and declined; that is a different finding from the
      # person who never got there.
      assert second.skipped == 1
      assert second.not_reached == 1

      assert third.answered == 1
      assert third.not_reached == 3
    end

    test "lists every question even when nobody answered" do
      {survey, questions} = survey_with([:scale, :open_text])

      funnel = Results.completion_funnel(survey.id)

      assert length(funnel) == length(questions)
      assert Enum.all?(funnel, &(&1.answered == 0))
      assert Enum.all?(funnel, &(&1.reach_rate == nil))
    end
  end

  describe "frequencies/2" do
    test "counts choices in the author's order, not alphabetically or by count" do
      survey = insert(:survey, status: :published)
      {config, [fast, right, slow]} = choice_config(["Too fast", "About right", "Too slow"])
      question = insert(:survey_question, survey: survey, type: :single_choice, config: config)

      for choice <- [slow, slow, right, fast, slow] do
        respond(survey, [{question, %{"choice_id" => choice}}])
      end

      {:ok, result} = Results.frequencies(question)

      # The order respondents saw, which is the order a reader expects.
      assert Enum.map(result.rows, & &1.label) == ["Too fast", "About right", "Too slow"]
      assert Enum.map(result.rows, & &1.count) == [1, 1, 3]
      assert result.valid == 5
    end

    test "percent is out of everyone, valid_percent out of those who answered" do
      survey = insert(:survey, status: :published)
      {config, [yes, _no]} = choice_config(["Yes", "No"])
      question = insert(:survey_question, survey: survey, type: :single_choice, config: config)

      for _ <- 1..3, do: respond(survey, [{question, %{"choice_id" => yes}}])
      respond(survey, [{question, :skip}])

      {:ok, result} = Results.frequencies(question)

      row = Enum.find(result.rows, &(&1.key == yes))

      # The distinction SPSS makes, and the one that stops a
      # refusal-heavy question looking like a consensus.
      assert row.valid_percent == 1.0
      assert row.percent == 0.75
      assert result.skipped == 1
      assert result.total == 4
    end

    test "cumulative percent runs down the rows" do
      survey = insert(:survey, status: :published)
      {config, [a, b, c]} = choice_config(["A", "B", "C"])
      question = insert(:survey_question, survey: survey, type: :single_choice, config: config)

      for choice <- [a, a, b, c], do: respond(survey, [{question, %{"choice_id" => choice}}])

      {:ok, result} = Results.frequencies(question)

      assert Enum.map(result.rows, & &1.cumulative_percent) == [0.5, 0.75, 1.0]
    end

    test "a multi-select reports shares of respondents, not of selections" do
      survey = insert(:survey, status: :published)
      {config, [a, b, _c]} = choice_config(["Labs", "Lectures", "Reading"])
      question = insert(:survey_question, survey: survey, type: :multiple_choice, config: config)

      respond(survey, [{question, %{"choice_ids" => [a, b]}}])
      respond(survey, [{question, %{"choice_ids" => [a]}}])

      {:ok, result} = Results.frequencies(question)

      assert result.multi_select?
      assert result.valid == 2

      # "100% of people picked Labs", not "67% of selections were Labs".
      labs = Enum.find(result.rows, &(&1.key == a))
      assert labs.valid_percent == 1.0
    end

    test "a scale's categories are its points, labelled where the author named them" do
      survey = insert(:survey, status: :published)

      question =
        insert(:survey_question,
          survey: survey,
          type: :scale,
          config: %{
            "min" => 1,
            "max" => 3,
            "step" => 1,
            "point_labels" => ["Never", "Sometimes", "Always"]
          }
        )

      for n <- [1, 2, 2, 3], do: respond(survey, [{question, scale(n)}])

      {:ok, result} = Results.frequencies(question)

      assert Enum.map(result.rows, & &1.label) == ["1 - Never", "2 - Sometimes", "3 - Always"]
      assert Enum.map(result.rows, & &1.count) == [1, 2, 1]
    end

    test "a yes/no question uses its own labels" do
      survey = insert(:survey, status: :published)

      question =
        insert(:survey_question,
          survey: survey,
          type: :dichotomous,
          config: %{"yes_label" => "Would recommend", "no_label" => "Would not"}
        )

      respond(survey, [{question, %{"choice_id" => "yes"}}])
      respond(survey, [{question, %{"choice_id" => "no"}}])

      {:ok, result} = Results.frequencies(question)

      assert Enum.map(result.rows, & &1.label) == ["Would recommend", "Would not"]
    end

    test "free text has no frequency distribution" do
      {survey, [question]} = survey_with([:open_text])
      _ = survey

      assert {:error, :not_categorical} = Results.frequencies(question)
    end
  end

  describe "descriptives/2" do
    test "summarises a scale" do
      {survey, [question]} = survey_with([:scale])

      for n <- [1, 2, 3, 4, 5], do: respond(survey, [{question, scale(n)}])

      {:ok, result} = Results.descriptives(question)

      assert result.n == 5
      assert result.mean == 3.0
      assert result.median == 3.0
    end

    test "refuses to average option ids" do
      survey = insert(:survey, status: :published)
      {config, _ids} = choice_config(["A", "B"])
      question = insert(:survey_question, survey: survey, type: :single_choice, config: config)

      # The whole reason measurement levels are recorded: this would produce a
      # number with no meaning at all.
      assert {:error, :not_quantitative} = Results.descriptives(question)
    end

    test "a matrix is summarised row by row" do
      survey = insert(:survey, status: :published)
      row_a = Ecto.UUID.generate()
      row_b = Ecto.UUID.generate()

      question =
        insert(:survey_question,
          survey: survey,
          type: :multi_scale,
          config: %{
            "rows" => [%{"id" => row_a, "text" => "Pace"}, %{"id" => row_b, "text" => "Depth"}],
            "min" => 1,
            "max" => 5,
            "step" => 1
          }
        )

      respond(survey, [
        {question, %{"row_id" => row_a, "number" => 2}},
        {question, %{"row_id" => row_b, "number" => 5}}
      ])

      respond(survey, [
        {question, %{"row_id" => row_a, "number" => 4}},
        {question, %{"row_id" => row_b, "number" => 5}}
      ])

      {:ok, result} = Results.descriptives(question)

      [pace, depth] = result.per_row
      assert pace.label == "Pace"
      assert pace.mean == 3.0
      assert depth.mean == 5.0
    end

    test "skipped answers are excluded from the mean but counted" do
      {survey, [question]} = survey_with([:scale])

      respond(survey, [{question, scale(4)}])
      respond(survey, [{question, scale(2)}])
      respond(survey, [{question, :skip}])

      {:ok, result} = Results.descriptives(question)

      assert result.n == 2
      assert result.mean == 3.0
      assert result.skipped == 1
    end
  end

  describe "crosstab/3" do
    test "tabulates two single-choice questions with a chi-square" do
      survey = insert(:survey, status: :published)
      {pace_config, [fast, slow]} = choice_config(["Too fast", "Too slow"])
      {year_config, [first, second]} = choice_config(["First year", "Second year"])

      pace = insert(:survey_question, survey: survey, type: :single_choice, config: pace_config)
      year = insert(:survey_question, survey: survey, type: :single_choice, config: year_config)

      pairs =
        List.duplicate({first, fast}, 8) ++
          List.duplicate({first, slow}, 2) ++
          List.duplicate({second, fast}, 3) ++
          List.duplicate({second, slow}, 7)

      for {y, p} <- pairs do
        respond(survey, [{year, %{"choice_id" => y}}, {pace, %{"choice_id" => p}}])
      end

      {:ok, result} = Results.crosstab(year, pace)

      assert result.row_labels == ["First year", "Second year"]
      assert result.col_labels == ["Too fast", "Too slow"]
      assert result.table == [[8, 2], [3, 7]]
      assert result.row_totals == [10, 10]
      assert result.col_totals == [11, 9]
      assert result.n == 20

      assert {:ok, test} = result.test
      assert test.df == 1
      assert test.p < 0.05
    end

    test "only counts respondents who answered both questions" do
      survey = insert(:survey, status: :published)
      {config_a, [a1, _a2]} = choice_config(["A1", "A2"])
      {config_b, [b1, _b2]} = choice_config(["B1", "B2"])

      qa = insert(:survey_question, survey: survey, type: :single_choice, config: config_a)
      qb = insert(:survey_question, survey: survey, type: :single_choice, config: config_b)

      respond(survey, [{qa, %{"choice_id" => a1}}, {qb, %{"choice_id" => b1}}])
      # Answered only one: pairwise deletion drops them from this table only.
      respond(survey, [{qa, %{"choice_id" => a1}}])

      {:ok, result} = Results.crosstab(qa, qb)

      assert result.n == 1
    end

    test "refuses question types that are not one category per respondent" do
      survey = insert(:survey, status: :published)
      {config, _ids} = choice_config(["A", "B"])

      single = insert(:survey_question, survey: survey, type: :single_choice, config: config)
      multi = insert(:survey_question, survey: survey, type: :multiple_choice, config: config)
      text = insert(:survey_question, survey: survey, type: :open_text, config: %{})

      # A multi-select respondent belongs to several rows at once, which is
      # not a contingency table.
      assert {:error, :not_crosstabbable} = Results.crosstab(single, multi)
      assert {:error, :not_crosstabbable} = Results.crosstab(multi, single)
      assert {:error, :not_crosstabbable} = Results.crosstab(single, text)
    end

    test "no overlapping respondents is insufficient data, not an empty table" do
      survey = insert(:survey, status: :published)
      {config, _ids} = choice_config(["A", "B"])
      qa = insert(:survey_question, survey: survey, type: :single_choice, config: config)
      qb = insert(:survey_question, survey: survey, type: :single_choice, config: config)

      assert {:error, :insufficient_data} = Results.crosstab(qa, qb)
    end
  end

  describe "correlations/2" do
    test "reports Pearson and Spearman for each pair" do
      {survey, [a, b]} = survey_with([:scale, :scale])

      for {x, y} <- [{1, 1}, {2, 2}, {3, 3}, {4, 5}, {5, 4}] do
        respond(survey, [{a, scale(x)}, {b, scale(y)}])
      end

      {:ok, result} = Results.correlations(survey.id)

      assert [pair] = result.pairs
      assert pair.n == 5
      assert {:ok, %{r: r}} = pair.pearson
      assert {:ok, %{rho: rho}} = pair.spearman
      assert r > 0.8
      assert rho > 0.8
    end

    test "leaves out questions that cannot be correlated" do
      {survey, [_scale1, _text, _scale2]} = survey_with([:scale, :open_text, :numeric])

      {:ok, result} = Results.correlations(survey.id)

      assert Enum.map(result.questions, & &1.type) == [:scale, :numeric]
    end

    test "needs two quantitative questions to correlate anything" do
      {survey, _questions} = survey_with([:scale, :open_text])

      assert {:error, :insufficient_questions} = Results.correlations(survey.id)
    end

    test "surfaces the statistical error rather than inventing a number" do
      {survey, [a, b]} = survey_with([:scale, :scale])

      # Everyone answered 3 to the second question: a real finding, but not a
      # correlation of zero.
      for x <- [1, 2, 3, 4], do: respond(survey, [{a, scale(x)}, {b, scale(3)}])

      {:ok, result} = Results.correlations(survey.id)

      assert [pair] = result.pairs
      assert {:error, :no_variance} = pair.pearson
    end
  end

  describe "compare_groups/2" do
    test "compares two cohorts on a scale, parametrically and by ranks" do
      {survey, [question]} = survey_with([:scale])
      a = insert(:cohort, name: "Group A")
      b = insert(:cohort, name: "Group B")

      for n <- [5, 5, 4, 5], do: respond(survey, [{question, scale(n)}], cohort_id: a.id)
      for n <- [2, 1, 2, 1], do: respond(survey, [{question, scale(n)}], cohort_id: b.id)

      {:ok, result} = Results.compare_groups(question)

      assert result.kind == :quantitative
      assert length(result.groups) == 2

      # Both tests, side by side: when they disagree that is informative.
      assert {:ok, %{p: parametric_p}} = result.parametric
      assert {:ok, %{p: rank_p}} = result.nonparametric
      assert parametric_p < 0.01
      assert rank_p < 0.05
    end

    test "three or more cohorts get ANOVA and Kruskal-Wallis" do
      {survey, [question]} = survey_with([:scale])

      for {values, _} <- Enum.with_index([[5, 5, 4], [3, 3, 2], [1, 1, 2]]) do
        cohort = insert(:cohort)
        for n <- values, do: respond(survey, [{question, scale(n)}], cohort_id: cohort.id)
      end

      {:ok, result} = Results.compare_groups(question)

      assert {:ok, %{df_between: 2}} = result.parametric
      assert {:ok, %{df: 2}} = result.nonparametric
    end

    test "individually enrolled respondents are one group, not one each" do
      {survey, [question]} = survey_with([:scale])
      cohort = insert(:cohort)

      for n <- [5, 4, 5], do: respond(survey, [{question, scale(n)}], cohort_id: cohort.id)
      for n <- [1, 2, 1], do: respond(survey, [{question, scale(n)}])

      {:ok, result} = Results.compare_groups(question)

      # A comparison with a group of one per person is not a comparison.
      assert length(result.groups) == 2
      assert Enum.any?(result.groups, &(&1.label == :individual))
    end

    test "a nominal question is compared with a chi-square, not a mean" do
      survey = insert(:survey, status: :published)
      {config, [yes, no]} = choice_config(["Yes", "No"])
      question = insert(:survey_question, survey: survey, type: :single_choice, config: config)

      a = insert(:cohort)
      b = insert(:cohort)

      for choice <- [yes, yes, yes, no],
          do: respond(survey, [{question, %{"choice_id" => choice}}], cohort_id: a.id)

      for choice <- [no, no, no, yes],
          do: respond(survey, [{question, %{"choice_id" => choice}}], cohort_id: b.id)

      {:ok, result} = Results.compare_groups(question)

      assert result.kind == :nominal
      assert result.category_labels == ["Yes", "No"]
      assert result.table == [[3, 1], [1, 3]]
      assert {:ok, %{df: 1}} = result.test
    end

    test "a nominal comparison handles a cohort alongside self-paced students" do
      survey = insert(:survey, status: :published)
      {config, [yes, no]} = choice_config(["Yes", "No"])
      question = insert(:survey_question, survey: survey, type: :single_choice, config: config)
      cohort = insert(:cohort)

      for choice <- [yes, yes, no] do
        respond(survey, [{question, %{"choice_id" => choice}}], cohort_id: cohort.id)
      end

      for choice <- [no, no], do: respond(survey, [{question, %{"choice_id" => choice}}])

      {:ok, result} = Results.compare_groups(question)

      # The group keys are cohort ids *and* the :individual atom, so the
      # comparator has to cope with both; the self-paced group sorts last
      # because it is a residual category, not a cohort.
      assert List.last(result.group_keys) == :individual
      assert result.table == [[2, 1], [0, 2]]
    end

    test "one group is nothing to compare" do
      {survey, [question]} = survey_with([:scale])
      cohort = insert(:cohort)

      for n <- [4, 5], do: respond(survey, [{question, scale(n)}], cohort_id: cohort.id)

      assert {:error, :insufficient_groups} = Results.compare_groups(question)
    end
  end

  describe "reliability/2" do
    setup do
      survey = insert(:survey, status: :published)
      row_ids = Enum.map(1..3, fn _ -> Ecto.UUID.generate() end)

      question =
        insert(:survey_question,
          survey: survey,
          type: :multi_scale,
          config: %{
            "rows" =>
              Enum.zip(row_ids, ["Clear", "Useful", "Well paced"])
              |> Enum.map(fn {id, text} -> %{"id" => id, "text" => text} end),
            "min" => 1,
            "max" => 5,
            "step" => 1
          }
        )

      %{survey: survey, question: question, row_ids: row_ids}
    end

    test "computes alpha over the battery with per-item diagnostics", ctx do
      [r1, r2, r3] = ctx.row_ids

      for {a, b, c} <- [{4, 4, 5}, {5, 4, 5}, {3, 3, 2}, {4, 5, 4}, {5, 5, 4}, {2, 2, 3}] do
        respond(ctx.survey, [
          {ctx.question, %{"row_id" => r1, "number" => a}},
          {ctx.question, %{"row_id" => r2, "number" => b}},
          {ctx.question, %{"row_id" => r3, "number" => c}}
        ])
      end

      {:ok, result} = Results.reliability(ctx.question)

      assert result.item_count == 3
      assert result.n == 6
      assert result.row_labels == ["Clear", "Useful", "Well paced"]
      assert is_float(result.alpha)
      assert length(result.items) == 3
    end

    test "drops respondents who left a row blank, and says how many", ctx do
      [r1, r2, r3] = ctx.row_ids

      for {a, b, c} <- [{4, 4, 5}, {5, 4, 5}, {3, 3, 2}, {2, 2, 1}] do
        respond(ctx.survey, [
          {ctx.question, %{"row_id" => r1, "number" => a}},
          {ctx.question, %{"row_id" => r2, "number" => b}},
          {ctx.question, %{"row_id" => r3, "number" => c}}
        ])
      end

      # Two rows only: alpha describes how items hang together for the *same*
      # people, so this respondent cannot contribute.
      respond(ctx.survey, [
        {ctx.question, %{"row_id" => r1, "number" => 5}},
        {ctx.question, %{"row_id" => r2, "number" => 1}}
      ])

      {:ok, result} = Results.reliability(ctx.question)

      assert result.n == 4
      assert result.dropped_incomplete == 1
    end

    test "only a matrix is a battery", ctx do
      {:ok, scale_question} = Surveys.add_question(ctx.survey, :scale)

      assert {:error, :not_a_battery} = Results.reliability(scale_question)
    end
  end

  describe "verbatims/2" do
    test "lists the free-text answers with their labels" do
      {survey, [question]} = survey_with([:open_text])
      cohort = insert(:cohort, name: "Group A")

      respond(survey, [{question, %{"text" => "More lab time"}}], cohort_id: cohort.id)
      respond(survey, [{question, %{"text" => "Fewer slides"}}], cohort_id: cohort.id)
      respond(survey, [{question, :skip}], cohort_id: cohort.id)

      {:ok, result} = Results.verbatims(question)

      texts = Enum.map(result.entries, & &1.text)
      assert "More lab time" in texts
      assert "Fewer slides" in texts
      assert length(result.entries) == 2
      assert result.skipped == 1

      # Every entry is labelled, and for a cohort respondent the label names
      # the cohort rather than the person.
      for entry <- result.entries do
        assert entry.label.kind == :cohort
        assert entry.label.cohort_name == "Group A"
      end
    end

    test "only an open-text question has verbatims" do
      {survey, [question]} = survey_with([:scale])
      _ = survey

      assert {:error, :not_open_text} = Results.verbatims(question)
    end
  end

  describe "respondent_labels/1" do
    test "a cohort respondent is a cohort and a number, never a name" do
      {survey, [question]} = survey_with([:scale])
      cohort = insert(:cohort, name: "Group A")

      student = insert(:account)
      insert(:profile, owner: student, first_name: "Anna", last_name: "Petrova")

      response =
        insert(:survey_response,
          survey: survey,
          account_id: student.id,
          cohort_id: cohort.id
        )

      {:ok, _} = Surveys.save_answer(response, question, scale(4))

      labels = survey.id |> Results.list_responses_for_labels() |> Results.respondent_labels()
      label = Map.fetch!(labels, response.id)

      assert label.kind == :cohort
      assert label.cohort_name == "Group A"
      assert label.text == "Group A · #1"

      # The promise the survey makes to the student.
      refute label.text =~ "Anna"
      refute label.text =~ "Petrova"
      refute label.text =~ student.id
    end

    test "an individually enrolled respondent is named, having no group to hide in" do
      {survey, [_question]} = survey_with([:scale])
      student = insert(:account)
      insert(:profile, owner: student, first_name: "Boris", last_name: "Ivanov")

      response = insert(:survey_response, survey: survey, account_id: student.id, cohort_id: nil)

      labels = survey.id |> Results.list_responses_for_labels() |> Results.respondent_labels()
      label = Map.fetch!(labels, response.id)

      assert label.kind == :identified
      assert label.text =~ "Boris"
    end

    test "numbers are by response id, not by start time" do
      {survey, [_question]} = survey_with([:scale])
      cohort = insert(:cohort, name: "Group A")

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      responses =
        for minutes <- [0, 1, 2] do
          insert(:survey_response,
            survey: survey,
            account_id: insert(:account).id,
            cohort_id: cohort.id,
            started_at: DateTime.add(now, minutes * 60, :second)
          )
        end

      labels = survey.id |> Results.list_responses_for_labels() |> Results.respondent_labels()

      numbered =
        responses
        |> Enum.map(&Map.fetch!(labels, &1.id).number)

      # Numbering by started_at would let anyone who knows who answered first
      # put a name to "respondent 1", so the order follows the random id.
      assert Enum.sort(numbered) == [1, 2, 3]

      by_id_order =
        responses
        |> Enum.sort_by(& &1.id)
        |> Enum.map(&Map.fetch!(labels, &1.id).number)

      assert by_id_order == [1, 2, 3]
    end

    test "numbers restart per cohort" do
      {survey, [_question]} = survey_with([:scale])
      a = insert(:cohort, name: "Group A")
      b = insert(:cohort, name: "Group B")

      for cohort <- [a, a, b] do
        insert(:survey_response,
          survey: survey,
          account_id: insert(:account).id,
          cohort_id: cohort.id
        )
      end

      labels = survey.id |> Results.list_responses_for_labels() |> Results.respondent_labels()

      numbers_by_cohort =
        labels
        |> Map.values()
        |> Enum.group_by(& &1.cohort_id, & &1.number)
        |> Map.new(fn {cohort_id, numbers} -> {cohort_id, Enum.sort(numbers)} end)

      assert numbers_by_cohort[a.id] == [1, 2]
      assert numbers_by_cohort[b.id] == [1]
    end
  end

  describe "cohort scoping" do
    test "every aggregate can be narrowed to one cohort" do
      {survey, [question]} = survey_with([:scale])
      a = insert(:cohort)
      b = insert(:cohort)

      for n <- [5, 5], do: respond(survey, [{question, scale(n)}], cohort_id: a.id)
      for n <- [1, 1], do: respond(survey, [{question, scale(n)}], cohort_id: b.id)

      {:ok, all} = Results.descriptives(question)
      {:ok, just_a} = Results.descriptives(question, cohort_id: a.id)

      assert all.n == 4
      assert all.mean == 3.0
      assert just_a.n == 2
      assert just_a.mean == 5.0

      {:ok, frequencies} = Results.frequencies(question, cohort_id: b.id)
      assert frequencies.valid == 2
    end
  end
end
