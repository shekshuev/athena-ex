defmodule Athena.Surveys.Results do
  @moduledoc """
  Reading a survey's answers back: frequencies, descriptives, crosstabs,
  correlations, group comparisons, reliability and verbatims.

  The SQL lives here and the mathematics lives in `Athena.Surveys.Stats`, so
  the arithmetic stays testable without a database and this module stays
  testable without reimplementing it.

  ## What the typed projections buy

  Every aggregate reads `value_numeric`, `value_text` or `value_choice_ids`
  rather than decoding each respondent's `value` map, which is the entire
  reason those columns exist. A frequency count is `unnest` plus `group by`; a
  mean is `avg`.

  Two places deliberately load rows instead of aggregating in SQL: the
  quantitative summaries, because the median, the quartiles, the skewness and
  the kurtosis all need the values themselves and one pass that fetches them
  beats four queries that each compute one moment; and reliability, which
  needs the whole respondent-by-item matrix by definition. A survey has
  hundreds or low thousands of respondents, not millions, so this is the right
  trade - and if that ever stops being true, the place to change is here, not
  in `Stats`.

  ## Missing answers

  A missing answer and a refused one are different findings and are counted
  separately throughout: `skipped` is a stored row saying "I saw this and
  declined", while no row at all means the respondent never got there -
  because of branching, or because they stopped. Lumping them together would
  make a question that people refuse look identical to one they never reached.

  Correlations and crosstabs use **pairwise** deletion: a pair is included
  when the respondent answered both of its questions. Listwise deletion across
  a branching survey would throw away nearly everyone.

  ## Who answered

  `respondent_labels/1` is the single place that decides whether a response
  may be shown against a person. A response carrying a `cohort_id` reached the
  survey through a cohort and is labelled by cohort and an opaque number;
  only an individually enrolled respondent is named. Every table, list and
  export goes through it, which is what keeps that rule from being
  re-implemented slightly differently in each view.
  """

  import Ecto.Query

  alias Athena.Learning
  alias Athena.Repo
  alias Athena.Surveys.{QuestionTypes, Stats, SurveyAnswer, SurveyQuestion, SurveyResponse}

  @doc """
  Headline numbers for a survey: how many people started, how many finished,
  and how many cohorts are represented.
  """
  @spec summary(binary()) :: map()
  def summary(survey_id) do
    counts =
      SurveyResponse
      |> where([r], r.survey_id == ^survey_id)
      |> group_by([r], r.status)
      |> select([r], {r.status, count(r.id)})
      |> Repo.all()
      |> Map.new()

    started = counts |> Map.values() |> Enum.sum()
    completed = Map.get(counts, :completed, 0)

    %{
      started: started,
      completed: completed,
      in_progress: Map.get(counts, :in_progress, 0),
      abandoned: Map.get(counts, :abandoned, 0),
      completion_rate: if(started > 0, do: completed / started, else: nil),
      cohort_count: cohort_count(survey_id),
      identified_count: identified_count(survey_id)
    }
  end

  defp cohort_count(survey_id) do
    SurveyResponse
    |> where([r], r.survey_id == ^survey_id and not is_nil(r.cohort_id))
    |> select([r], count(r.cohort_id, :distinct))
    |> Repo.one()
  end

  defp identified_count(survey_id) do
    SurveyResponse
    |> where([r], r.survey_id == ^survey_id and is_nil(r.cohort_id))
    |> Repo.aggregate(:count)
  end

  @doc """
  How many people answered each question, in survey order.

  The most useful single view an instructor has, and it comes free from
  storing answers as they are given: the question where the count drops is
  the one that is too long, too personal, or badly worded. A survey that only
  recorded finished responses could not show this at all.
  """
  @spec completion_funnel(binary()) :: [map()]
  def completion_funnel(survey_id) do
    questions = ordered_questions(survey_id)
    started = SurveyResponse |> where([r], r.survey_id == ^survey_id) |> Repo.aggregate(:count)

    counts =
      SurveyAnswer
      |> join(:inner, [a], q in SurveyQuestion, on: q.id == a.question_id)
      |> where([_a, q], q.survey_id == ^survey_id)
      |> group_by([a, _q], [a.question_id, a.skipped])
      |> select([a, _q], {a.question_id, a.skipped, count(a.response_id, :distinct)})
      |> Repo.all()
      |> Enum.reduce(%{}, fn {question_id, skipped, count}, acc ->
        key = if skipped, do: :skipped, else: :answered
        Map.update(acc, question_id, %{key => count}, &Map.put(&1, key, count))
      end)

    Enum.map(questions, fn question ->
      per_question = Map.get(counts, question.id, %{})
      answered = Map.get(per_question, :answered, 0)
      skipped = Map.get(per_question, :skipped, 0)

      %{
        question: question,
        answered: answered,
        skipped: skipped,
        # Not "missing" in the usual sense: with branching, a respondent who
        # never saw a question is not a non-response to it.
        not_reached: max(started - answered - skipped, 0),
        reach_rate: if(started > 0, do: (answered + skipped) / started, else: nil)
      }
    end)
  end

  @doc """
  Frequencies for one question: the count and share of each answer, with
  refusals counted separately.

  `valid_percent` is out of the people who gave an answer, `percent` out of
  everyone who reached the question - the distinction SPSS makes, and the one
  that stops a refused-heavy question looking like a consensus.

  For a multi-select, the shares are out of *respondents*, not selections, so
  they add to more than 100% and say "62% of people picked this" rather than
  something uninterpretable.
  """
  @spec frequencies(SurveyQuestion.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def frequencies(%SurveyQuestion{} = question, opts \\ []) do
    case QuestionTypes.measurement(question.type) do
      :text ->
        {:error, :not_categorical}

      measurement ->
        rows = categorical_rows(question, opts)
        skipped = skipped_count(question, opts)
        respondents = rows |> Enum.map(& &1.count) |> Enum.sum()
        distinct_respondents = answered_count(question, opts)

        base = if multi_select?(question), do: distinct_respondents, else: respondents

        {:ok,
         %{
           question: question,
           measurement: measurement,
           multi_select?: multi_select?(question),
           rows: percentages(rows, base, distinct_respondents + skipped),
           valid: distinct_respondents,
           skipped: skipped,
           total: distinct_respondents + skipped
         }}
    end
  end

  defp percentages(rows, valid_base, total_base) do
    rows
    |> Enum.map_reduce(0, fn row, running ->
      running = running + row.count

      {Map.merge(row, %{
         valid_percent: share(row.count, valid_base),
         percent: share(row.count, total_base),
         cumulative_percent: share(running, valid_base)
       }), running}
    end)
    |> elem(0)
  end

  defp share(_count, 0), do: nil
  defp share(count, base), do: count / base

  # Choice-shaped answers live in `value_choice_ids`; a scale's categories are
  # its points, which live in `value_numeric`. Both come back as {label, count}
  # with the label resolved from the question's own config, so a results table
  # never shows a raw id.
  defp categorical_rows(%{type: type} = question, opts) when type in [:scale, :nps] do
    question
    |> numeric_value_counts(opts)
    |> Enum.map(fn {value, count} ->
      %{key: value, label: scale_label(question, value), count: count}
    end)
    |> Enum.sort_by(& &1.key)
  end

  defp categorical_rows(%{type: :multi_scale} = question, opts) do
    # A matrix has no single distribution; its rows each have one. Reported
    # per row so the shape is the same as every other question's.
    question
    |> numeric_row_counts(opts)
    |> Enum.map(fn {{row_key, value}, count} ->
      %{
        key: {row_key, value},
        label: "#{row_label(question, row_key)}: #{scale_label(question, value)}",
        count: count
      }
    end)
    |> Enum.sort_by(& &1.key)
  end

  defp categorical_rows(question, opts) do
    labels = choice_labels(question)

    question
    |> choice_counts(opts)
    |> Enum.map(fn {choice_id, count} ->
      %{key: choice_id, label: Map.get(labels, choice_id, choice_id), count: count}
    end)
    |> Enum.sort_by(&option_position(question, &1.key))
  end

  defp choice_counts(question, opts) do
    unnested =
      question
      |> answer_scope(opts)
      |> select([a], %{choice: fragment("unnest(?)", a.value_choice_ids)})

    from(u in subquery(unnested), group_by: u.choice, select: {u.choice, count()})
    |> Repo.all()
    |> Map.new()
  end

  defp numeric_value_counts(question, opts) do
    question
    |> answer_scope(opts)
    |> where([a], not is_nil(a.value_numeric))
    |> group_by([a], a.value_numeric)
    |> select([a], {a.value_numeric, count()})
    |> Repo.all()
  end

  defp numeric_row_counts(question, opts) do
    question
    |> answer_scope(opts)
    |> where([a], not is_nil(a.value_numeric))
    |> group_by([a], [a.row_key, a.value_numeric])
    |> select([a], {{a.row_key, a.value_numeric}, count()})
    |> Repo.all()
  end

  @doc """
  Mean, median, spread and shape for a quantitative question.

  Refuses a nominal question outright rather than averaging option ids, which
  would produce a number with no meaning whatsoever. That refusal is the
  reason `QuestionTypes.measurement/1` exists.
  """
  @spec descriptives(SurveyQuestion.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def descriptives(%SurveyQuestion{} = question, opts \\ []) do
    cond do
      question.type == :multi_scale ->
        {:ok, %{question: question, per_row: matrix_descriptives(question, opts)}}

      QuestionTypes.quantitative?(question.type) ->
        values = numeric_values(question, opts)

        {:ok,
         Map.merge(Stats.descriptives(values), %{
           question: question,
           skipped: skipped_count(question, opts)
         })}

      true ->
        {:error, :not_quantitative}
    end
  end

  defp matrix_descriptives(question, opts) do
    by_row =
      question
      |> answer_scope(opts)
      |> where([a], not is_nil(a.value_numeric))
      |> select([a], {a.row_key, a.value_numeric})
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    question
    |> rows()
    |> Enum.map(fn row ->
      values = Map.get(by_row, row["id"], [])

      Map.merge(Stats.descriptives(values), %{row_key: row["id"], label: row["text"]})
    end)
  end

  @doc """
  The NPS bands for an `:nps` question, plus the score itself.

  The score is the promoter share minus the detractor share, in points - the
  only definition of NPS there is, and the reason the question type fixes its
  range: a mean of 0-10 answers is not an NPS, and the bands are the measure.
  """
  @spec nps_bands(SurveyQuestion.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def nps_bands(question, opts \\ [])

  def nps_bands(%SurveyQuestion{type: :nps} = question, opts) do
    values = numeric_values(question, opts)
    n = length(values)

    if n == 0 do
      {:error, :insufficient_data}
    else
      promoters = Enum.count(values, &(&1 >= 9))
      detractors = Enum.count(values, &(&1 <= 6))
      passives = n - promoters - detractors

      {:ok,
       %{
         question: question,
         n: n,
         promoters: promoters,
         passives: passives,
         detractors: detractors,
         score: (promoters - detractors) / n * 100
       }}
    end
  end

  def nps_bands(%SurveyQuestion{}, _opts), do: {:error, :not_nps}

  @doc """
  A matrix question's counts as `{row_label, point} => count`, with the scale's
  points - the shape the stacked Likert chart takes.

  Labels rather than row ids as keys, because the chart's axis is labels and a
  caller should not have to join the two back together.
  """
  @spec matrix_counts(SurveyQuestion.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def matrix_counts(question, opts \\ [])

  def matrix_counts(%SurveyQuestion{type: :multi_scale} = question, opts) do
    labels = question |> rows() |> Map.new(&{&1["id"], &1["text"]})

    counts =
      question
      |> numeric_row_counts(opts)
      |> Enum.reduce(%{}, fn {{row_key, value}, count}, acc ->
        case Map.get(labels, row_key) do
          nil -> acc
          label -> Map.put(acc, {label, value}, count)
        end
      end)

    {:ok,
     %{
       question: question,
       row_labels: question |> rows() |> Enum.map(& &1["text"]),
       points: scale_points(question),
       counts: counts
     }}
  end

  def matrix_counts(%SurveyQuestion{}, _opts), do: {:error, :not_a_battery}

  @doc "The points of a question's scale, as stored."
  @spec scale_points(SurveyQuestion.t()) :: [number()]
  def scale_points(question) do
    min = question.config["min"] || 1
    max = question.config["max"] || 5
    step = max(question.config["step"] || 1, 1)

    min
    |> Stream.iterate(&(&1 + step))
    |> Enum.take_while(&(&1 <= max))
    |> Enum.map(&(&1 / 1))
  end

  @doc """
  Crosstab of two questions with a chi-square test of independence.

  Only defined for questions where each respondent falls in exactly one
  category - single choice, yes/no, and the points of a scale. A multi-select
  respondent belongs to several rows at once, which is not a contingency
  table, and `{:error, :not_crosstabbable}` says so instead of quietly
  double-counting them.
  """
  @spec crosstab(SurveyQuestion.t(), SurveyQuestion.t(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def crosstab(%SurveyQuestion{} = row_question, %SurveyQuestion{} = col_question, opts \\ []) do
    with :ok <- ensure_crosstabbable(row_question),
         :ok <- ensure_crosstabbable(col_question) do
      pairs = category_pairs(row_question, col_question, opts)

      if pairs == [] do
        {:error, :insufficient_data}
      else
        # The author's option order, not the raw ids: sorting a crosstab's
        # headers by UUID would shuffle them differently from the frequency
        # table of the same question.
        row_keys =
          pairs
          |> Enum.map(&elem(&1, 0))
          |> Enum.uniq()
          |> Enum.sort_by(&category_order(row_question, &1))

        col_keys =
          pairs
          |> Enum.map(&elem(&1, 1))
          |> Enum.uniq()
          |> Enum.sort_by(&category_order(col_question, &1))

        table = tabulate(pairs, row_keys, col_keys)

        {:ok,
         %{
           row_question: row_question,
           col_question: col_question,
           row_labels: Enum.map(row_keys, &category_label(row_question, &1)),
           col_labels: Enum.map(col_keys, &category_label(col_question, &1)),
           table: table,
           row_totals: Enum.map(table, &Enum.sum/1),
           col_totals: Enum.zip_with(table, &Enum.sum/1),
           n: length(pairs),
           test: Stats.chi_square(table)
         }}
      end
    end
  end

  defp tabulate(pairs, row_keys, col_keys) do
    tally = Enum.frequencies(pairs)

    Enum.map(row_keys, fn row_key ->
      Enum.map(col_keys, &Map.get(tally, {row_key, &1}, 0))
    end)
  end

  defp ensure_crosstabbable(question) do
    cond do
      multi_select?(question) -> {:error, :not_crosstabbable}
      question.type == :multi_scale -> {:error, :not_crosstabbable}
      QuestionTypes.measurement(question.type) == :text -> {:error, :not_crosstabbable}
      question.type in [:ranking, :numeric] -> {:error, :not_crosstabbable}
      true -> :ok
    end
  end

  defp category_pairs(row_question, col_question, opts) do
    from(a in SurveyAnswer,
      join: b in SurveyAnswer,
      on: b.response_id == a.response_id,
      where:
        a.question_id == ^row_question.id and b.question_id == ^col_question.id and
          not a.skipped and not b.skipped,
      select: {a.value_choice_ids, a.value_numeric, b.value_choice_ids, b.value_numeric}
    )
    |> scope_to_cohort(opts)
    |> Repo.all()
    |> Enum.flat_map(fn {row_choices, row_number, col_choices, col_number} ->
      with row_key when not is_nil(row_key) <- single_category(row_choices, row_number),
           col_key when not is_nil(col_key) <- single_category(col_choices, col_number) do
        [{row_key, col_key}]
      else
        _ -> []
      end
    end)
  end

  defp single_category(choices, number) do
    case List.wrap(choices) do
      [one] -> one
      _ -> number
    end
  end

  defp category_order(_question, key) when is_number(key), do: {0, key, ""}

  defp category_order(question, key) when is_binary(key),
    do: {1, option_position(question, key), key}

  # Resolved once per comparison and handed to the caller, so a results table
  # does not look a cohort's name up per row inside its own render.
  defp group_names(keys) do
    names =
      keys
      |> Enum.filter(&is_binary/1)
      |> Learning.get_cohorts_map()
      |> Map.new(fn {id, cohort} -> {id, cohort.name} end)

    Map.new(keys, fn
      :individual -> {:individual, nil}
      cohort_id -> {cohort_id, Map.get(names, cohort_id)}
    end)
  end

  # By name, not by cohort id: ids are random UUIDs, so ordering by them puts
  # the same two groups in a different order on every run - which is both
  # unreadable and untestable. The self-paced group sorts last, being a
  # residual category rather than a cohort.
  defp sort_group_keys(keys, names) do
    Enum.sort_by(keys, fn
      :individual -> {1, ""}
      cohort_id -> {0, Map.get(names, cohort_id) || ""}
    end)
  end

  @doc """
  Pearson and Spearman between every pair of quantitative questions.

  Both, side by side, on purpose: on five-point scales they can disagree, and
  the disagreement is informative rather than a problem to resolve by picking
  one in advance.

  Pairwise deletion - a pair counts when the respondent answered both. With
  branching, listwise deletion would drop nearly everyone.
  """
  @spec correlations(binary(), keyword()) :: {:ok, map()} | {:error, atom()}
  def correlations(survey_id, opts \\ []) do
    questions =
      survey_id
      |> ordered_questions()
      |> Enum.filter(&(QuestionTypes.quantitative?(&1.type) and &1.type != :multi_scale))

    if length(questions) < 2 do
      {:error, :insufficient_questions}
    else
      pairs =
        for {a, i} <- Enum.with_index(questions),
            {b, j} <- Enum.with_index(questions),
            i < j do
          {xs, ys} = paired_values(a, b, opts)

          %{
            row: a,
            col: b,
            n: length(xs),
            pearson: Stats.pearson(xs, ys),
            spearman: Stats.spearman(xs, ys)
          }
        end

      {:ok, %{questions: questions, pairs: pairs}}
    end
  end

  defp paired_values(a, b, opts) do
    from(x in SurveyAnswer,
      join: y in SurveyAnswer,
      on: y.response_id == x.response_id,
      where:
        x.question_id == ^a.id and y.question_id == ^b.id and
          not x.skipped and not y.skipped and
          not is_nil(x.value_numeric) and not is_nil(y.value_numeric),
      select: {x.value_numeric, y.value_numeric}
    )
    |> scope_to_cohort(opts)
    |> Repo.all()
    |> Enum.unzip()
  end

  @doc """
  Compares how the cohorts answered one question.

  Chooses the test from the question's measurement level rather than letting a
  caller pick: a mean over option ids and a chi-square over a Likert scale are
  both easy to ask for and both meaningless.

  For a quantitative question it reports the parametric test *and* its
  rank-based counterpart. They almost always agree; when they do not, that is
  worth seeing, because it usually means the distribution is skewed enough
  that the mean was the wrong summary.
  """
  @spec compare_groups(SurveyQuestion.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def compare_groups(%SurveyQuestion{} = question, opts \\ []) do
    # Counted from the respondents, not from their numeric values: a nominal
    # question has no `value_numeric` at all, so deriving the group count from
    # one would report "not enough groups" for every categorical comparison.
    cond do
      group_count(question, opts) < 2 ->
        {:error, :insufficient_groups}

      QuestionTypes.quantitative?(question.type) ->
        quantitative_comparison(question, grouped_values(question, opts))

      QuestionTypes.measurement(question.type) == :nominal and not multi_select?(question) ->
        nominal_comparison(question, opts)

      true ->
        {:error, :not_comparable}
    end
  end

  defp group_count(question, opts) do
    question
    |> answer_scope(opts)
    |> join(:inner, [a], r in SurveyResponse, on: r.id == a.response_id)
    |> select([_a, r], r.cohort_id)
    |> distinct(true)
    |> Repo.all()
    |> Enum.map(&group_key/1)
    |> Enum.uniq()
    |> length()
  end

  defp quantitative_comparison(question, groups) do
    names = group_names(Map.keys(groups))
    labels = sort_group_keys(Map.keys(groups), names)
    values = Enum.map(labels, &Map.fetch!(groups, &1))

    {parametric, nonparametric} =
      case values do
        [a, b] -> {Stats.t_test(a, b), Stats.mann_whitney(a, b)}
        many -> {Stats.anova_one_way(many), Stats.kruskal_wallis(many)}
      end

    {:ok,
     %{
       kind: :quantitative,
       question: question,
       group_names: names,
       groups:
         Enum.map(labels, fn label ->
           %{
             label: label,
             name: Map.get(names, label),
             descriptives: Stats.descriptives(Map.fetch!(groups, label))
           }
         end),
       parametric: parametric,
       nonparametric: nonparametric
     }}
  end

  defp nominal_comparison(question, opts) do
    rows =
      question
      |> answer_scope(opts)
      |> join(:inner, [a], r in SurveyResponse, on: r.id == a.response_id)
      |> select([a, r], {r.cohort_id, a.value_choice_ids, a.value_numeric})
      |> Repo.all()
      |> Enum.flat_map(fn {cohort_id, choices, number} ->
        case single_category(choices, number) do
          nil -> []
          category -> [{group_key(cohort_id), category}]
        end
      end)

    names = rows |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> group_names()
    group_keys = rows |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> sort_group_keys(names)

    categories =
      rows |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort_by(&category_order(question, &1))

    tally = Enum.frequencies(rows)

    table =
      Enum.map(group_keys, fn group ->
        Enum.map(categories, fn category -> Map.get(tally, {group, category}, 0) end)
      end)

    {:ok,
     %{
       kind: :nominal,
       question: question,
       group_keys: group_keys,
       group_names: names,
       category_labels: Enum.map(categories, &category_label(question, &1)),
       table: table,
       test: Stats.chi_square(table)
     }}
  end

  defp grouped_values(question, opts) do
    question
    |> answer_scope(opts)
    |> join(:inner, [a], r in SurveyResponse, on: r.id == a.response_id)
    |> where([a, _r], not is_nil(a.value_numeric))
    |> select([a, r], {r.cohort_id, a.value_numeric})
    |> Repo.all()
    |> Enum.group_by(fn {cohort_id, _value} -> group_key(cohort_id) end, &elem(&1, 1))
  end

  # Individually enrolled respondents are one group, not one group each: a
  # comparison with a group of one per person is not a comparison.
  defp group_key(nil), do: :individual
  defp group_key(cohort_id), do: cohort_id

  @doc """
  Cronbach's alpha for a `:multi_scale` battery, with per-item diagnostics.

  Listwise by necessity: alpha describes how a set of items hang together for
  the same people, so a respondent who skipped one row of the matrix cannot
  contribute to it. The count that was dropped is reported, since a low alpha
  computed on a third of the sample means something different from a low alpha
  on all of it.
  """
  @spec reliability(SurveyQuestion.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def reliability(question, opts \\ [])

  def reliability(%SurveyQuestion{type: :multi_scale} = question, opts) do
    row_keys = question |> rows() |> Enum.map(& &1["id"])

    by_response =
      question
      |> answer_scope(opts)
      |> where([a], not is_nil(a.value_numeric))
      |> select([a], {a.response_id, a.row_key, a.value_numeric})
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), fn {_id, row_key, value} -> {row_key, value} end)
      |> Map.new(fn {response_id, entries} -> {response_id, Map.new(entries)} end)

    complete =
      by_response
      |> Enum.filter(fn {_id, values} -> Enum.all?(row_keys, &Map.has_key?(values, &1)) end)
      |> Enum.map(&elem(&1, 1))

    items = Enum.map(row_keys, fn row_key -> Enum.map(complete, &Map.fetch!(&1, row_key)) end)

    case Stats.cronbach_alpha(items) do
      {:ok, result} ->
        {:ok,
         Map.merge(result, %{
           question: question,
           row_labels: question |> rows() |> Enum.map(& &1["text"]),
           dropped_incomplete: map_size(by_response) - length(complete)
         })}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def reliability(%SurveyQuestion{}, _opts), do: {:error, :not_a_battery}

  @doc """
  The free-text answers to one question, each with the label its respondent
  may be shown under.

  Verbatims are where identity leaks if anywhere does - a sentence can
  identify its author however carefully the schema is arranged - so they go
  through `respondent_labels/1` like everything else, and the builder warns an
  author about this when they add an open-text question.
  """
  @spec verbatims(SurveyQuestion.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def verbatims(question, opts \\ [])

  def verbatims(%SurveyQuestion{type: :open_text} = question, opts) do
    rows =
      question
      |> answer_scope(opts)
      |> join(:inner, [a], r in SurveyResponse, on: r.id == a.response_id)
      |> where([a, _r], not is_nil(a.value_text) and a.value_text != "")
      |> select([a, r], {r.id, a.value_text, a.answered_at})
      |> order_by([a, _r], desc: a.answered_at)
      |> Repo.all()

    labels = question.survey_id |> list_responses_for_labels() |> respondent_labels()

    {:ok,
     %{
       question: question,
       entries:
         Enum.map(rows, fn {response_id, text, answered_at} ->
           %{text: text, answered_at: answered_at, label: Map.get(labels, response_id)}
         end),
       skipped: skipped_count(question, opts)
     }}
  end

  def verbatims(%SurveyQuestion{}, _opts), do: {:error, :not_open_text}

  @doc """
  How each response may be referred to, as `%{response_id => label}`.

  The one place that decides this. A response with a `cohort_id` reached the
  survey through a cohort, so it is shown as its cohort plus an opaque number
  and the respondent is never named. Only an individually enrolled respondent
  is named, because there is no group to report them inside.

  The number is positional within the cohort by response id - a random UUID -
  and deliberately not by start time: numbering by `started_at` would let
  anyone who knows who answered first put a name to "respondent 1".
  """
  @spec respondent_labels([SurveyResponse.t()]) :: %{binary() => map()}
  def respondent_labels(responses) do
    cohort_names =
      responses
      |> Enum.map(& &1.cohort_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Learning.get_cohorts_map()
      |> Map.new(fn {id, cohort} -> {id, cohort.name} end)

    account_names = identified_account_names(responses)

    responses
    |> Enum.group_by(& &1.cohort_id)
    |> Enum.flat_map(fn
      {nil, individual} ->
        Enum.map(individual, fn response ->
          {response.id,
           %{
             kind: :identified,
             cohort_id: nil,
             text: Map.get(account_names, response.account_id, "?")
           }}
        end)

      {cohort_id, cohort_responses} ->
        cohort_responses
        |> Enum.sort_by(& &1.id)
        |> Enum.with_index(1)
        |> Enum.map(fn {response, index} ->
          {response.id,
           %{
             kind: :cohort,
             cohort_id: cohort_id,
             cohort_name: Map.get(cohort_names, cohort_id),
             number: index,
             text: "#{Map.get(cohort_names, cohort_id, "?")} · ##{index}"
           }}
        end)
    end)
    |> Map.new()
  end

  defp identified_account_names(responses) do
    ids =
      responses
      |> Enum.filter(&is_nil(&1.cohort_id))
      |> Enum.map(& &1.account_id)
      |> Enum.uniq()

    if ids == [] do
      %{}
    else
      ids
      |> Athena.Identity.get_accounts_map()
      |> Map.new(fn {id, account} -> {id, account_name(account)} end)
    end
  end

  defp account_name(%{profile: %{first_name: first, last_name: last}})
       when is_binary(first) and is_binary(last),
       do: String.trim("#{first} #{last}")

  defp account_name(%{login: login}), do: login
  defp account_name(_account), do: "?"

  @doc "Responses of a survey, loaded for labelling."
  @spec list_responses_for_labels(binary()) :: [SurveyResponse.t()]
  def list_responses_for_labels(survey_id) do
    SurveyResponse
    |> where([r], r.survey_id == ^survey_id)
    |> select([r], %{id: r.id, cohort_id: r.cohort_id, account_id: r.account_id})
    |> Repo.all()
  end

  # -- shared scoping -------------------------------------------------------

  defp ordered_questions(survey_id) do
    SurveyQuestion
    |> where([q], q.survey_id == ^survey_id)
    |> order_by([q], asc: q.position)
    |> Repo.all()
  end

  defp answer_scope(question, opts) do
    SurveyAnswer
    |> where([a], a.question_id == ^question.id and not a.skipped)
    |> scope_to_cohort(opts)
  end

  # A cohort filter applies to the *response*, so it has to reach the answers
  # through a join even when the caller only asked about one question.
  defp scope_to_cohort(query, opts) do
    case Keyword.get(opts, :cohort_id) do
      nil ->
        query

      cohort_id ->
        query
        |> join(:inner, [a], scope in SurveyResponse, on: scope.id == a.response_id)
        |> where([_a, scope], scope.cohort_id == ^cohort_id)
    end
  end

  defp answered_count(question, opts) do
    question
    |> answer_scope(opts)
    |> select([a], count(a.response_id, :distinct))
    |> Repo.one()
  end

  defp skipped_count(question, opts) do
    SurveyAnswer
    |> where([a], a.question_id == ^question.id and a.skipped)
    |> scope_to_cohort(opts)
    |> select([a], count(a.response_id, :distinct))
    |> Repo.one()
  end

  defp numeric_values(question, opts) do
    question
    |> answer_scope(opts)
    |> where([a], not is_nil(a.value_numeric))
    |> select([a], a.value_numeric)
    |> Repo.all()
  end

  # -- label resolution -----------------------------------------------------

  defp multi_select?(%{type: type}), do: type in [:multiple_choice, :ranking]

  defp rows(question), do: List.wrap(question.config["rows"])

  defp options(question), do: List.wrap(question.config["options"])

  defp row_label(question, row_key) do
    case Enum.find(rows(question), &(&1["id"] == row_key)) do
      nil -> row_key
      row -> row["text"]
    end
  end

  defp scale_label(question, value) do
    labels = List.wrap(question.config["point_labels"])
    min = question.config["min"] || 0
    step = max(question.config["step"] || 1, 1)
    index = trunc((value - min) / step)

    case Enum.at(labels, index) do
      nil -> format_number(value)
      "" -> format_number(value)
      label -> "#{format_number(value)} - #{label}"
    end
  end

  defp format_number(value) when is_float(value) do
    if value == Float.round(value),
      do: trunc(value) |> Integer.to_string(),
      else: to_string(value)
  end

  defp format_number(value), do: to_string(value)

  defp choice_labels(%{type: :dichotomous} = question) do
    %{
      QuestionTypes.yes_choice_id() => question.config["yes_label"],
      QuestionTypes.no_choice_id() => question.config["no_label"]
    }
  end

  defp choice_labels(%{type: :ranking} = question) do
    question.config["items"] |> List.wrap() |> Map.new(&{&1["id"], &1["text"]})
  end

  defp choice_labels(question) do
    question
    |> options()
    |> Map.new(&{&1["id"], &1["text"]})
    |> Map.put(QuestionTypes.other_choice_id(), "Other")
  end

  defp option_position(%{type: :dichotomous}, key) do
    if key == QuestionTypes.yes_choice_id(), do: 0, else: 1
  end

  defp option_position(%{type: :ranking} = question, key) do
    index_of(List.wrap(question.config["items"]), key)
  end

  defp option_position(question, key), do: index_of(options(question), key)

  # Keeps a results table in the order the author wrote the options, which is
  # the order respondents saw and the order a reader expects - not
  # alphabetical, and not by count.
  defp index_of(list, key) do
    case Enum.find_index(list, &(&1["id"] == key)) do
      nil -> length(list)
      index -> index
    end
  end

  defp category_label(question, key) when is_number(key), do: scale_label(question, key)

  defp category_label(question, key) do
    Map.get(choice_labels(question), key, key)
  end
end
