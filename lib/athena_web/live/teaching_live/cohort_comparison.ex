defmodule AthenaWeb.TeachingLive.CohortComparison do
  @moduledoc """
  Turns `Athena.Engagement.cohort_summary/3` for several cohorts into what
  the comparison screen shows: plain-language indicators grouped by
  meaning, each cohort's value next to the course average (all selected
  cohorts added together), how far off it is and whether that is good or
  bad, the sentences worth reading first, and a topics × groups matrix.

  Pure functions, no database.
  """
  use Gettext, backend: AthenaWeb.Gettext

  @pass_mark 50

  @indicators [
    %{group: :progress, key: :progress, kind: :percent, better: :higher},
    %{group: :progress, key: :inactive, kind: :percent, better: :lower},
    %{group: :results, key: :score, kind: :score, better: :higher},
    %{group: :results, key: :first_try, kind: :percent, better: :higher},
    %{group: :learning, key: :slacking, kind: :percent, better: :lower},
    %{group: :learning, key: :struggling, kind: :percent, better: :lower},
    %{group: :integrity, key: :integrity, kind: :percent, better: :lower},
    %{group: :integrity, key: :flagged, kind: :percent, better: :lower}
  ]

  @doc "Indicators in display order, each `%{group, key, kind, better}`."
  def indicators, do: @indicators

  @doc "Indicator groups in display order."
  def groups, do: [:progress, :results, :learning, :integrity]

  @doc "Label of an indicator group."
  def group_label(:progress), do: gettext("Progress")
  def group_label(:results), do: gettext("Results")
  def group_label(:learning), do: gettext("How they learn")
  def group_label(:integrity), do: gettext("Integrity")

  @doc "Name of an indicator."
  def label(:progress), do: gettext("Course completed")
  def label(:inactive), do: gettext("Not engaging in this period")
  def label(:score), do: gettext("Average score")
  def label(:first_try), do: gettext("Passed on the first attempt")
  def label(:slacking), do: gettext("Rush through the material")
  def label(:struggling), do: gettext("Get stuck")
  def label(:integrity), do: gettext("Exam violations")
  def label(:flagged), do: gettext("Attempts flagged by the cheating monitor")

  @doc "What an indicator means, in one sentence - the row's `?` tooltip."
  def help(:progress),
    do: gettext("Average share of the course's blocks each student has completed.")

  def help(:inactive),
    do: gettext("Share of students who opened nothing during the selected period.")

  def help(:score),
    do: gettext("Average best score over every graded task submitted, whole course.")

  def help(:first_try),
    do: gettext("Share of submitted tasks that reached the pass mark on the very first attempt.")

  def help(:slacking),
    do:
      gettext(
        "Share of students with repeated signs of rushing: much less time than the group, unread text, skipped video, pasted answers."
      )

  def help(:struggling),
    do:
      gettext(
        "Share of students with repeated signs of getting stuck: much more time than the group, changing answers, going back, re-running code."
      )

  def help(:integrity),
    do: gettext("Share of students with at least one sign of dishonest behaviour during an exam.")

  def help(:flagged),
    do:
      gettext(
        "Share of exam attempts the cheating monitor rated high risk, or the teacher confirmed as a violation."
      )

  @doc """
  Value of `key` for one summary (or the merge of several), `nil` when
  there is nothing to measure. Percent indicators are 0..100.
  """
  @spec value(map(), atom()) :: number() | nil
  def value(%{students: 0}, key)
      when key in [:progress, :inactive, :slacking, :struggling, :integrity],
      do: nil

  def value(s, :progress), do: s.progress_sum / s.students
  def value(s, :inactive), do: Map.get(s.levels, :inactive, 0) / s.students * 100
  def value(s, :slacking), do: s.slacking_students / s.students * 100
  def value(s, :struggling), do: s.struggling_students / s.students * 100
  def value(s, :integrity), do: s.integrity_students / s.students * 100
  def value(%{scored: 0}, :score), do: nil
  def value(s, :score), do: s.score_sum / s.scored
  def value(%{attempted: 0}, key) when key in [:first_try, :flagged], do: nil
  def value(s, :first_try), do: s.first_try / s.attempted * 100
  def value(s, :flagged), do: s.flagged_attempts / s.attempted * 100

  @doc "The selected cohorts added together - what \"course average\" means here."
  @spec merge([map()]) :: map()
  def merge(summaries) do
    Enum.reduce(summaries, empty(), fn s, acc ->
      %{
        students: acc.students + s.students,
        progress_sum: acc.progress_sum + s.progress_sum,
        levels: Map.merge(acc.levels, s.levels, fn _level, a, b -> a + b end),
        slacking_students: acc.slacking_students + s.slacking_students,
        struggling_students: acc.struggling_students + s.struggling_students,
        integrity_students: acc.integrity_students + s.integrity_students,
        scored: acc.scored + s.scored,
        score_sum: acc.score_sum + s.score_sum,
        attempted: acc.attempted + s.attempted,
        first_try: acc.first_try + s.first_try,
        flagged_attempts: acc.flagged_attempts + s.flagged_attempts,
        sections: Map.merge(acc.sections, s.sections, fn _id, a, b -> merge_section(a, b) end)
      }
    end)
  end

  defp empty do
    %{
      students: 0,
      progress_sum: 0,
      levels: %{},
      slacking_students: 0,
      struggling_students: 0,
      integrity_students: 0,
      scored: 0,
      score_sum: 0,
      attempted: 0,
      first_try: 0,
      flagged_attempts: 0,
      sections: %{}
    }
  end

  defp merge_section(a, b) do
    %{
      scored: a.scored + b.scored,
      score_sum: a.score_sum + b.score_sum,
      done: a.done + b.done,
      total: a.total + b.total
    }
  end

  @doc """
  How far `value` is from the course average for `indicator`:
  `%{level: 0 | 1 | 2, good?: boolean}` - level 1 from 10 points apart
  (8 for scores), level 2 from 20 (15 for scores).
  """
  @spec deviation(number() | nil, number() | nil, map()) :: %{level: 0..2, good?: boolean()}
  def deviation(value, average, _indicator) when is_nil(value) or is_nil(average),
    do: %{level: 0, good?: true}

  def deviation(value, average, indicator) do
    {small, large} = if indicator.kind == :score, do: {8, 15}, else: {10, 20}
    diff = value - average

    level =
      cond do
        abs(diff) >= large -> 2
        abs(diff) >= small -> 1
        true -> 0
      end

    %{level: level, good?: if(indicator.better == :higher, do: diff > 0, else: diff < 0)}
  end

  @doc "A value for display: \"64%\", \"72\" or \"–\"."
  @spec format(number() | nil, map()) :: String.t()
  def format(nil, _indicator), do: "–"
  def format(value, %{kind: :percent}), do: "#{round(value)}%"
  def format(value, _indicator), do: "#{round(value)}"

  @doc """
  The sentences worth reading first, at most `limit`: every clearly worse
  cohort × indicator (level 2), topics hard for every group, and sections a
  cohort is far behind in. `cohorts` is `[{cohort, summary}]`, `sections`
  the course's sections in order.
  """
  @spec insights([{map(), map()}], [map()], pos_integer()) :: [String.t()]
  def insights(cohorts, sections, limit \\ 6) do
    merged = cohorts |> Enum.map(&elem(&1, 1)) |> merge()

    (worse_indicators(cohorts, merged) ++
       hard_topics(sections, merged, cohorts) ++ lagging_sections(cohorts, sections, merged))
    |> Enum.take(limit)
  end

  defp worse_indicators(cohorts, merged) do
    for indicator <- @indicators,
        {cohort, summary} <- cohorts,
        value = value(summary, indicator.key),
        average = value(merged, indicator.key),
        %{level: 2, good?: false} <- [deviation(value, average, indicator)] do
      gettext("%{group}: %{indicator} - %{value} against %{average} on average.",
        group: cohort.name,
        indicator: String.downcase(label(indicator.key)),
        value: format(value, indicator),
        average: format(average, indicator)
      )
    end
  end

  # Only meaningful with more than one group: "hard for everyone".
  defp hard_topics(_sections, _merged, cohorts) when length(cohorts) < 2, do: []

  defp hard_topics(sections, merged, cohorts) do
    for section <- sections,
        %{scored: scored} = stats <- [Map.get(merged.sections, section.id)],
        scored >= 3,
        average = stats.score_sum / scored,
        average < @pass_mark + 10,
        Enum.all?(cohorts, fn {_cohort, s} ->
          score = section_score(s, section.id)
          is_nil(score) or score < @pass_mark + 10
        end) do
      gettext("“%{section}” is hard for every group: average score %{score}.",
        section: section.title,
        score: round(average)
      )
    end
  end

  defp lagging_sections(cohorts, sections, merged) do
    for section <- sections,
        %{total: total} = stats <- [Map.get(merged.sections, section.id)],
        total > 0,
        average = stats.done / total * 100,
        {cohort, summary} <- cohorts,
        mine = section_completion(summary, section.id),
        mine != nil and average - mine >= 25 do
      gettext("%{group} is behind in “%{section}”: %{mine}% completed against %{average}%.",
        group: cohort.name,
        section: section.title,
        mine: round(mine),
        average: round(average)
      )
    end
  end

  @doc "Average score of one cohort in one section, or `nil`."
  def section_score(summary, section_id) do
    case Map.get(summary.sections, section_id) do
      %{scored: scored, score_sum: sum} when scored > 0 -> sum / scored
      _ -> nil
    end
  end

  @doc "Completion percent of one cohort in one section, or `nil`."
  def section_completion(summary, section_id) do
    case Map.get(summary.sections, section_id) do
      %{total: total, done: done} when total > 0 -> done / total * 100
      _ -> nil
    end
  end
end
