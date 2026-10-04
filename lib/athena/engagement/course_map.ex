defmodule Athena.Engagement.CourseMap do
  @moduledoc """
  The rules behind the Course Map: when a block of a course is a "problem
  spot" for a cohort, and how serious it is. Pure functions over the
  per-block statistics `Athena.Engagement.Metrics.course_map/3` gathers.

  A cohort-wide issue is only raised once at least `map_min_students`
  students are behind the number (opened the block, or were graded on it),
  so two students never make a block "problematic".

    * `:low_scores` - fewer than `map_low_pass_share` of graded students
      reached the pass mark (critical below `map_critical_pass_share`);
    * `:many_attempts` - `map_attempts_avg` attempts or more on average;
    * `:skimmed` - at least `map_behaviour_share` of those who opened it
      rushed through it (any superficial-learning flag);
    * `:stuck` - at least `map_behaviour_share` of them got stuck (any
      difficulty flag);
    * `:high_backtrack_rate` / `:high_hesitation_rate` - the content flags
      of `Athena.Engagement.Metrics.flag_concerns/1`.
  """

  @type issue :: %{key: atom(), value: number(), critical?: boolean()}

  @doc "Issues for one block's cohort statistics, most serious first."
  @spec cohort_issues(map(), keyword()) :: [issue()]
  def cohort_issues(stats, config \\ []) do
    min = Keyword.get(config, :map_min_students, 3)
    behaviour = Keyword.get(config, :map_behaviour_share, 0.4)

    [
      low_scores(stats, min, config),
      many_attempts(stats, min, config),
      share_issue(:skimmed, stats.skimmed, stats.opened, min, behaviour),
      share_issue(:stuck, stats.stuck, stats.opened, min, behaviour),
      content_issue(:high_backtrack_rate, stats, :backtrack_rate),
      content_issue(:high_hesitation_rate, stats, :hesitation_rate)
    ]
    |> Enum.reject(&is_nil/1)
  end

  @doc "`:high`, `:medium` or `nil` (fine) for a list of issues."
  @spec severity([issue()]) :: :high | :medium | nil
  def severity([]), do: nil
  def severity(issues), do: if(Enum.any?(issues, & &1.critical?), do: :high, else: :medium)

  @doc """
  Severity of one student's signals on one block: an exam violation or a
  low score is `:high`, anything else `:medium`.
  """
  @spec student_severity([map()]) :: :high | :medium | nil
  def student_severity([]), do: nil

  def student_severity(signals) do
    if Enum.any?(signals, &(&1.category == :integrity or &1.key == :low_score)),
      do: :high,
      else: :medium
  end

  @doc """
  The most problematic blocks first: by severity, then number of issues,
  then course order (`position`). `entries` are `{position, block_id,
  severity, issue_count}` tuples; returns block ids.
  """
  @spec rank([{non_neg_integer(), binary(), atom() | nil, non_neg_integer()}], pos_integer()) ::
          [binary()]
  def rank(entries, limit) do
    entries
    |> Enum.reject(fn {_position, _id, severity, _count} -> is_nil(severity) end)
    |> Enum.sort_by(fn {position, _id, severity, count} ->
      {if(severity == :high, do: 0, else: 1), -count, position}
    end)
    |> Enum.take(limit)
    |> Enum.map(&elem(&1, 1))
  end

  defp low_scores(%{scored: scored, passed: passed}, min, config) when scored >= min do
    share = passed / scored

    if share < Keyword.get(config, :map_low_pass_share, 0.6),
      do: %{
        key: :low_scores,
        value: share,
        critical?: share < Keyword.get(config, :map_critical_pass_share, 0.4)
      }
  end

  defp low_scores(_stats, _min, _config), do: nil

  defp many_attempts(%{attempted: attempted, attempts_avg: avg}, min, config)
       when attempted >= min and is_number(avg) do
    if avg >= Keyword.get(config, :map_attempts_avg, 2.5),
      do: %{key: :many_attempts, value: avg, critical?: false}
  end

  defp many_attempts(_stats, _min, _config), do: nil

  defp share_issue(key, count, opened, min, threshold) when opened >= min do
    share = count / opened
    if share >= threshold, do: %{key: key, value: share, critical?: false}
  end

  defp share_issue(_key, _count, _opened, _min, _threshold), do: nil

  defp content_issue(key, stats, rate_key) do
    if key in stats.content_flags,
      do: %{key: key, value: Map.get(stats, rate_key) || 0, critical?: false}
  end
end
