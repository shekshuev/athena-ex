defmodule Athena.Engagement.StudentAssessment do
  @moduledoc """
  Why a student needs attention, as explicit, named signals - and the one
  status ("level") those signals add up to. No hidden weights: every level
  is a plain rule over signal counts (see `level/2`), so the dashboard can
  always list exactly what put a student where they are.

  Signals come from five places:

    * behaviour on blocks (`:slacking`, `:struggling`, `:integrity`) - the
      `Athena.Engagement.Metrics.flag_concerns/1` flags, with what they were
      measured against;
    * graded work (`:performance`) - a low score, or many attempts, on a
      task submitted inside the window, each with how the student went
      through the theory before it (`:theory`);
    * course progress (`:progress`) - blocks most of the cohort has
      completed but this student hasn't, or overall progress well behind
      the cohort's median;
    * activity (`:activity`) - nothing at all in the window while the rest
      of the cohort was active.

  Group comparisons (medians) are only made once
  `min_group_for_baseline` students have data, so a tiny group never
  defines "normal".
  """

  alias Athena.Content.Block

  @levels [:inactive, :integrity, :not_mastering, :behind, :superficial, :struggling, :on_track]

  @type signal :: %{
          required(:key) => atom(),
          required(:category) => atom(),
          optional(:block_id) => binary(),
          optional(:value) => number() | nil,
          optional(:baseline) => number() | nil,
          optional(:basis) => atom(),
          optional(:peers) => non_neg_integer() | nil,
          optional(:theory) => [map()]
        }

  @doc "Every level, most urgent first."
  @spec levels() :: [atom()]
  def levels, do: @levels

  @doc """
  Assesses every student in `context.students`. `context`:

    * `:blocks` - the blocks in scope, in course order;
    * `:flagged_blocks` - `%{account_id => [flagged block]}` as built by
      `Athena.Engagement.Metrics` (each with `:details` per flag);
    * `:active` - `MapSet` of students with any activity in the window;
    * `:cells` - gradebook cells `%{{account_id, block_id} => cell}`;
    * `:completed` - `%{account_id => MapSet of completed block ids}`;
    * `:progress` - `%{account_id => percent}`;
    * `:window_start` - `DateTime` or `nil` (whole course);
    * `:theory` - `fn account_id, block -> [theory review] end`.

  Returns `%{account_id => %{level: atom, signals: [signal]}}`.
  """
  @spec assess_cohort(map()) :: %{binary() => %{level: atom(), signals: [signal()]}}
  def assess_cohort(context) do
    config = Application.get_env(:athena, Athena.Engagement, [])
    group = group_stats(context, config)

    patterns = Map.new(context.students, &{&1, block_pattern(&1, context)})
    group_shares = group_pattern_shares(patterns, config)

    Map.new(context.students, fn account_id ->
      signals =
        activity_signals(account_id, context) ++
          flag_signals(Map.get(context.flagged_blocks, account_id, [])) ++
          performance_signals(account_id, context, group, config) ++
          progress_signals(account_id, context, group, config)

      pattern = judge_pattern(Map.fetch!(patterns, account_id), group_shares, config)
      facts = Map.put(pattern, :missed_enough?, missed_enough?(signals, group, config))

      {account_id, %{level: level(signals, facts, config), signals: signals, pattern: pattern}}
    end)
  end

  # How many of the blocks a student visited in the window show rushing /
  # getting stuck - a share, so a 400-block course and a 20-block course
  # are judged alike.
  defp block_pattern(account_id, context) do
    flagged = Map.get(context.flagged_blocks, account_id, [])
    visited = Map.get(context.visited, account_id, 0)

    %{
      visited: visited,
      slacking_blocks: Enum.count(flagged, &(&1.slacking_flags != [])),
      struggling_blocks: Enum.count(flagged, &(&1.struggling_flags != []))
    }
  end

  defp group_pattern_shares(patterns, config) do
    min_peers = Keyword.get(config, :min_group_for_baseline, 5)
    visited = patterns |> Map.values() |> Enum.filter(&(&1.visited > 0))

    %{
      slacking: median_if(Enum.map(visited, &(&1.slacking_blocks / &1.visited)), min_peers),
      struggling: median_if(Enum.map(visited, &(&1.struggling_blocks / &1.visited)), min_peers)
    }
  end

  # A pattern counts when it covers enough blocks, a big enough share of the
  # visited ones, and clearly more than is usual in this group.
  defp judge_pattern(pattern, group_shares, config) do
    judge = fn blocks, group_share ->
      share = if pattern.visited > 0, do: blocks / pattern.visited, else: 0.0

      fires? =
        blocks >= Keyword.get(config, :pattern_min_blocks, 3) and
          share >= Keyword.get(config, :pattern_block_share, 0.25) and
          (is_nil(group_share) or
             share >= Keyword.get(config, :pattern_group_factor, 2) * group_share)

      %{blocks: blocks, share: share, group_share: group_share, fires?: fires?}
    end

    %{
      visited: pattern.visited,
      slacking: judge.(pattern.slacking_blocks, group_shares.slacking),
      struggling: judge.(pattern.struggling_blocks, group_shares.struggling)
    }
  end

  defp missed_enough?(signals, group, config) do
    missed = Enum.count(signals, &(&1.key == :missed_block))

    missed >= Keyword.get(config, :missed_blocks_for_behind, 5) and
      group.group_done_blocks > 0 and
      missed / group.group_done_blocks >= Keyword.get(config, :missed_blocks_share, 0.1)
  end

  @doc """
  The level a student's signals and patterns add up to - the first rule
  that matches, most urgent first:

    * `:inactive` - no activity at all in the window;
    * `:integrity` - at least `student_radar_integrity_threshold` exam
      integrity signals;
    * `:not_mastering` - at least `not_mastering_min_low_scores` low scores
      (below the group, see `low_score/3`), or at least two tasks that took
      many more attempts than usual *and* still ended below the pass mark -
      retrying until it works is persistence, not a problem;
    * `:behind` - overall progress well behind the cohort, or missing enough
      of the blocks the cohort has done (`facts.missed_enough?`);
    * `:superficial` / `:struggling` - rushing / getting stuck as a pattern
      across the visited blocks (`facts.slacking.fires?` /
      `facts.struggling.fires?`), not a single block;
    * `:on_track` - otherwise.
  """
  @spec level([signal()], map(), keyword()) :: atom()
  def level(signals, facts \\ %{}, config \\ []) do
    count = fn key -> Enum.count(signals, &(&1.key == key)) end
    in_category = fn category -> Enum.count(signals, &(&1.category == category)) end
    fires? = fn key -> match?(%{fires?: true}, Map.get(facts, key)) end

    cond do
      count.(:inactive) > 0 ->
        :inactive

      in_category.(:integrity) >= Keyword.get(config, :student_radar_integrity_threshold, 1) ->
        :integrity

      count.(:low_score) >= Keyword.get(config, :not_mastering_min_low_scores, 2) or
          Enum.count(signals, &(&1.key == :many_attempts and &1[:unresolved?])) >= 2 ->
        :not_mastering

      count.(:behind_progress) > 0 or Map.get(facts, :missed_enough?, false) ->
        :behind

      fires?.(:slacking) ->
        :superficial

      fires?.(:struggling) ->
        :struggling

      true ->
        :on_track
    end
  end

  # Group statistics

  defp group_stats(context, config) do
    min_peers = Keyword.get(config, :min_group_for_baseline, 5)
    students = context.students
    gradable = Enum.filter(context.blocks, &Block.gradable?/1)

    per_block =
      Map.new(gradable, fn block ->
        cells =
          students |> Enum.map(&Map.get(context.cells, {&1, block.id})) |> Enum.reject(&is_nil/1)

        scores = for %{state: :scored, score: score} <- cells, do: score
        attempts = Enum.map(cells, & &1.attempts)

        {block.id,
         %{
           score_median: median_if(scores, min_peers),
           score_peers: length(scores),
           attempts_median: median_if(attempts, min_peers),
           attempts_peers: length(attempts)
         }}
      end)

    completion_share =
      Map.new(context.blocks, fn block ->
        done =
          Enum.count(
            students,
            &MapSet.member?(Map.get(context.completed, &1, MapSet.new()), block.id)
          )

        {block.id, if(students == [], do: 0.0, else: done / length(students))}
      end)

    progress = Enum.map(students, &Map.get(context.progress, &1, 0.0))
    share = Keyword.get(config, :missed_block_group_share, 0.6)

    %{
      per_block: per_block,
      completion_share: completion_share,
      enough_students?: length(students) >= min_peers,
      progress_median: median_if(progress, min_peers),
      group_done_blocks: Enum.count(completion_share, fn {_id, s} -> s >= share end),
      any_active?: MapSet.size(context.active) > 0
    }
  end

  defp median_if(values, min_peers) when length(values) >= min_peers do
    sorted = Enum.sort(values)
    count = length(sorted)
    middle = div(count, 2)

    if rem(count, 2) == 1,
      do: Enum.at(sorted, middle),
      else: (Enum.at(sorted, middle - 1) + Enum.at(sorted, middle)) / 2
  end

  defp median_if(_values, _min_peers), do: nil

  # Signals

  # Only meaningful when someone else in the cohort *was* active - an empty
  # week for everybody is a holiday, not a student problem.
  defp activity_signals(account_id, context) do
    if MapSet.size(context.active) > 0 and not MapSet.member?(context.active, account_id),
      do: [%{key: :inactive, category: :activity, basis: :count}],
      else: []
  end

  defp flag_signals(flagged_blocks) do
    for flagged <- flagged_blocks,
        {category, flags} <- [
          slacking: flagged.slacking_flags,
          struggling: flagged.struggling_flags,
          integrity: flagged.integrity_flags
        ],
        flag <- flags do
      flagged.details
      |> Map.get(flag, %{basis: :pattern})
      |> Map.merge(%{key: flag, category: category, block_id: flagged.block_id})
    end
  end

  defp performance_signals(account_id, context, group, config) do
    for block <- context.blocks,
        Block.gradable?(block),
        cell = Map.get(context.cells, {account_id, block.id}),
        cell != nil,
        in_window?(cell, context.window_start),
        signal <- task_signals(cell, Map.fetch!(group.per_block, block.id), config) do
      Map.merge(signal, %{
        category: :performance,
        block_id: block.id,
        theory: context.theory.(account_id, block)
      })
    end
  end

  defp in_window?(_cell, nil), do: true
  defp in_window?(cell, since), do: DateTime.compare(cell.submitted_at, since) != :lt

  defp task_signals(cell, stats, config) do
    low_score(cell, stats, config) ++ many_attempts(cell, stats, config)
  end

  defp low_score(%{state: :scored, score: score}, stats, config) do
    threshold = Keyword.get(config, :low_score_threshold, 50)
    gap = Keyword.get(config, :low_score_group_gap, 30)
    median = stats.score_median

    cond do
      # A task most of the group fails is a problem with the task (it shows
      # up on the Course Map), not with this student - below the pass mark
      # only counts when the group itself passes it.
      score < threshold and (is_nil(median) or median >= threshold) ->
        [
          %{
            key: :low_score,
            value: score,
            baseline: median,
            basis: :absolute,
            peers: stats.score_peers,
            threshold: threshold
          }
        ]

      median && score <= median - gap ->
        [
          %{
            key: :low_score,
            value: score,
            baseline: median,
            basis: :group,
            peers: stats.score_peers
          }
        ]

      true ->
        []
    end
  end

  defp low_score(_cell, _stats, _config), do: []

  defp many_attempts(%{attempts: attempts} = cell, stats, config) do
    min = Keyword.get(config, :many_attempts_min, 3)
    factor = Keyword.get(config, :many_attempts_group_factor, 2)

    fires? =
      case stats.attempts_median do
        nil -> attempts > min
        median -> attempts >= min and attempts >= factor * median
      end

    if fires?,
      do: [
        %{
          key: :many_attempts,
          value: attempts,
          baseline: stats.attempts_median,
          basis: if(stats.attempts_median, do: :group, else: :absolute),
          peers: stats.attempts_peers,
          unresolved?:
            not (cell.state == :scored and
                   cell.score >= Keyword.get(config, :low_score_threshold, 50))
        }
      ],
      else: []
  end

  defp progress_signals(account_id, context, group, config) do
    if group.enough_students? do
      missed_blocks(account_id, context, group, config) ++
        behind_progress(account_id, context, group, config)
    else
      []
    end
  end

  defp missed_blocks(account_id, context, group, config) do
    share = Keyword.get(config, :missed_block_group_share, 0.6)
    completed = Map.get(context.completed, account_id, MapSet.new())

    for block <- context.blocks,
        not MapSet.member?(completed, block.id),
        group_share = Map.fetch!(group.completion_share, block.id),
        group_share >= share do
      %{
        key: :missed_block,
        category: :progress,
        block_id: block.id,
        value: 0,
        baseline: group_share,
        basis: :group,
        peers: length(context.students)
      }
    end
  end

  defp behind_progress(account_id, context, group, config) do
    gap = Keyword.get(config, :behind_progress_gap, 20)
    progress = Map.get(context.progress, account_id, 0.0)

    if group.progress_median && progress < group.progress_median - gap,
      do: [
        %{
          key: :behind_progress,
          category: :progress,
          value: progress,
          baseline: group.progress_median,
          basis: :group,
          peers: length(context.students)
        }
      ],
      else: []
  end
end
