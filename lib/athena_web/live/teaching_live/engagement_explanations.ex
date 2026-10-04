defmodule AthenaWeb.TeachingLive.EngagementExplanations do
  @moduledoc """
  Plain-language wording for the Group Radar: what each student level
  means, what each signal (`Athena.Engagement.StudentAssessment`) measured
  against what, and what a teacher can do about it.

  Written for a teacher who has never seen the code: every line names the
  task, the student's number and the number it was compared with ("4 min
  on average, the group usually spends 9 min"), never a flag name.

  `block_names` everywhere is `%{block_id => "Section · 2. Exam"}` - the
  caller knows the course, this module only words things.
  """
  use Gettext, backend: AthenaWeb.Gettext

  alias Athena.Engagement

  # Levels

  @doc "Short name of a level."
  @spec level_label(atom()) :: String.t()
  def level_label(:inactive), do: gettext("Not engaging")
  def level_label(:integrity), do: gettext("Integrity risk")
  def level_label(:not_mastering), do: gettext("Not mastering the material")
  def level_label(:behind), do: gettext("Falling behind")
  def level_label(:superficial), do: gettext("Skimming")
  def level_label(:struggling), do: gettext("Struggling")
  def level_label(:on_track), do: gettext("On track")

  @doc "Badge tone of a level, most urgent red."
  @spec level_tone(atom()) :: String.t()
  def level_tone(level) when level in [:inactive, :integrity], do: "error"
  def level_tone(level) when level in [:not_mastering, :behind], do: "warning"
  def level_tone(level) when level in [:superficial, :struggling], do: "info"
  def level_tone(:on_track), do: "success"

  @doc "Hero icon of a level."
  @spec level_icon(atom()) :: String.t()
  def level_icon(:inactive), do: "hero-moon"
  def level_icon(:integrity), do: "hero-shield-exclamation"
  def level_icon(:not_mastering), do: "hero-academic-cap"
  def level_icon(:behind), do: "hero-clock"
  def level_icon(:superficial), do: "hero-forward"
  def level_icon(:struggling), do: "hero-lifebuoy"
  def level_icon(:on_track), do: "hero-check-circle"

  @doc """
  How each level is decided, in the order the rules are checked - for the
  "How is this decided?" explanation. Thresholds are read from the live
  config, so the text never drifts from the code.
  """
  @spec level_rules() :: [{atom(), String.t()}]
  def level_rules do
    config = Application.get_env(:athena, Athena.Engagement, [])
    get = &Keyword.get(config, &1, &2)

    rules = %{
      inactive:
        gettext("Opened nothing during the selected period, while classmates were active."),
      integrity:
        gettext(
          "At least %{count} sign(s) of dishonest behaviour during an exam: screenshots, copying, extra tabs, leaving the exam tab, pasted answers.",
          count: get.(:student_radar_integrity_threshold, 1)
        ),
      not_mastering:
        gettext(
          "At least %{count} tasks scored below %{score} while the group passed them (or %{gap}+ points below the group's median), or two tasks that took many more attempts than usual and still ended below the pass mark. A task most of the group fails is a problem with the task, not the student - see the course map.",
          count: get.(:not_mastering_min_low_scores, 2),
          score: get.(:low_score_threshold, 50),
          gap: get.(:low_score_group_gap, 30)
        ),
      behind:
        gettext(
          "Course progress %{gap}+ points behind the group's median, or skipped at least %{count} blocks (and %{share}% of them) that most of the group has already completed.",
          gap: get.(:behind_progress_gap, 20),
          count: get.(:missed_blocks_for_behind, 5),
          share: round(get.(:missed_blocks_share, 0.1) * 100)
        ),
      superficial:
        gettext(
          "Rushes through at least %{share}% of the blocks they open (and %{min}+ blocks), %{factor}× more often than is usual in the group: much less time than the group, not reading to the end, skipping video, pasting most of the answer.",
          share: round(get.(:pattern_block_share, 0.25) * 100),
          min: get.(:pattern_min_blocks, 3),
          factor: get.(:pattern_group_factor, 2)
        ),
      struggling:
        gettext(
          "Gets stuck on at least %{share}% of the blocks they open (and %{min}+ blocks), %{factor}× more often than is usual in the group: much more time than the group, changing answers again and again, re-running code within seconds.",
          share: round(get.(:pattern_block_share, 0.25) * 100),
          min: get.(:pattern_min_blocks, 3),
          factor: get.(:pattern_group_factor, 2)
        ),
      on_track: gettext("None of the above.")
    }

    Enum.map(Engagement.assessment_levels(), &{&1, Map.fetch!(rules, &1)})
  end

  # Signals

  @doc """
  `%{title, note, category, lines}` for one signal: a headline, a line with
  the student's number against what it was compared with, the signal's
  category label, and - for graded tasks - one line per theory block in
  front of it.
  """
  @spec explain(map(), map()) :: map()
  def explain(signal, block_names) do
    block = Map.get(block_names, signal[:block_id], gettext("a block"))

    %{
      title: title(signal, block),
      note: note(signal),
      category: category_label(signal.category),
      lines: theory_lines(signal, block_names)
    }
  end

  @doc """
  Reason chips for a table row: one per kind of signal, most urgent
  category first, each `%{label, count, tone}` - "Low score ×2".
  """
  @spec chips([map()]) :: [map()]
  def chips(signals) do
    signals
    |> Enum.group_by(&{&1.category, chip_key(&1)})
    |> Enum.map(fn {{category, key}, group} ->
      %{
        label: short_label(key),
        count: length(group),
        tone: category_tone(category),
        category: category
      }
    end)
    |> Enum.sort_by(&{category_rank(&1.category), -&1.count})
  end

  # Every exam violation reads the same in a chip; the details are in the drawer.
  defp chip_key(%{category: :integrity}), do: :integrity
  defp chip_key(%{key: key}), do: key

  @doc "Short name of a signal, for chips."
  @spec short_label(atom()) :: String.t()
  def short_label(:inactive), do: gettext("No activity")
  def short_label(:integrity), do: gettext("Exam violations")
  def short_label(:low_score), do: gettext("Low score")
  def short_label(:many_attempts), do: gettext("Many attempts")
  def short_label(:missed_block), do: gettext("Skipped blocks")
  def short_label(:behind_progress), do: gettext("Behind the group")
  def short_label(:fast_dwell), do: gettext("Too fast")
  def short_label(:slow_dwell), do: gettext("Very slow")
  def short_label(:shallow_scroll), do: gettext("Doesn't read to the end")
  def short_label(:heavy_paste), do: gettext("Pastes answers")
  def short_label(:video_skipped), do: gettext("Skips video")
  def short_label(:no_debug_cycle), do: gettext("Doesn't run code")
  def short_label(:hesitation), do: gettext("Changes answers")
  def short_label(:backtracked), do: gettext("Goes back")
  def short_label(:panic_debugging), do: gettext("Re-runs code")
  def short_label(key), do: key |> to_string() |> String.replace("_", " ")

  @doc "Badge tone of a signal category."
  @spec category_tone(atom()) :: String.t()
  def category_tone(category) when category in [:activity, :integrity], do: "error"
  def category_tone(category) when category in [:performance, :progress], do: "warning"
  def category_tone(_category), do: "info"

  @categories [:activity, :integrity, :performance, :progress, :slacking, :struggling]

  @doc "Signal categories, most urgent first."
  @spec categories() :: [atom()]
  def categories, do: @categories

  defp category_rank(category), do: Enum.find_index(@categories, &(&1 == category)) || 99

  @doc """
  One line about a rushing / getting-stuck pattern for the student card:
  "Rushing on 32% of opened blocks (usually 9% in this group)".
  """
  @spec pattern_line(atom(), map()) :: String.t()
  def pattern_line(kind, %{share: share, blocks: blocks, group_share: group_share}) do
    group = if group_share, do: share(group_share), else: "—"

    case kind do
      :slacking ->
        gettext(
          "Rushing on %{share} of opened blocks (%{blocks}); usually %{group} in this group",
          share: share(share),
          blocks: blocks,
          group: group
        )

      :struggling ->
        gettext("Stuck on %{share} of opened blocks (%{blocks}); usually %{group} in this group",
          share: share(share),
          blocks: blocks,
          group: group
        )
    end
  end

  @doc "Label of a signal category."
  @spec category_label(atom()) :: String.t()
  def category_label(:activity), do: gettext("Activity")
  def category_label(:integrity), do: gettext("Integrity")
  def category_label(:performance), do: gettext("Results")
  def category_label(:progress), do: gettext("Progress")
  def category_label(:slacking), do: gettext("Rushing")
  def category_label(:struggling), do: gettext("Difficulties")
  def category_label(_category), do: gettext("Other")

  defp title(%{key: :inactive}, _block), do: gettext("No activity in this period")

  defp title(%{key: :fast_dwell}, block),
    do: gettext("Went through “%{block}” too fast", block: block)

  defp title(%{key: :slow_dwell}, block),
    do: gettext("Spent unusually long on “%{block}”", block: block)

  defp title(%{key: :shallow_scroll}, block),
    do: gettext("Didn't read “%{block}” to the end", block: block)

  defp title(%{key: :heavy_paste}, block),
    do: gettext("Pasted most of the answer in “%{block}”", block: block)

  defp title(%{key: :video_skipped}, block),
    do: gettext("Skipped through the video “%{block}”", block: block)

  defp title(%{key: :no_debug_cycle}, block),
    do: gettext("Pasted code into “%{block}” without ever running it", block: block)

  defp title(%{key: :hesitation}, block),
    do: gettext("Kept changing the answer in “%{block}”", block: block)

  defp title(%{key: :backtracked}, block),
    do: gettext("Came back to “%{block}” after moving on", block: block)

  defp title(%{key: :panic_debugging}, block),
    do: gettext("Re-ran the code in “%{block}” every few seconds", block: block)

  defp title(%{key: :printscreen_attempted}, block),
    do: gettext("Tried to take a screenshot during “%{block}”", block: block)

  defp title(%{key: :copy_attempted}, block),
    do: gettext("Tried to copy from “%{block}”", block: block)

  defp title(%{key: :cut_attempted}, block),
    do: gettext("Tried to cut text in “%{block}”", block: block)

  defp title(%{key: :multi_tab_detected}, block),
    do: gettext("Opened “%{block}” in several tabs", block: block)

  defp title(%{key: :excessive_tab_switching}, block),
    do: gettext("Kept leaving the exam “%{block}”", block: block)

  defp title(%{key: :heavy_paste_on_exam}, block),
    do: gettext("Pasted answers into the exam “%{block}”", block: block)

  defp title(%{key: :low_score} = signal, block),
    do: gettext("Low score on “%{block}”: %{score}", block: block, score: signal.value)

  defp title(%{key: :many_attempts} = signal, block),
    do: gettext("%{count} attempts on “%{block}”", count: signal.value, block: block)

  defp title(%{key: :missed_block}, block),
    do: gettext("Hasn't done “%{block}” yet", block: block)

  defp title(%{key: :behind_progress}, _block), do: gettext("Behind the group in the course")
  defp title(%{key: key}, block), do: "#{key} · #{block}"

  defp note(%{key: :inactive}),
    do: gettext("Classmates were active, this student opened nothing.")

  defp note(%{key: key, basis: :expected} = signal) when key in [:fast_dwell, :slow_dwell] do
    gettext("%{value} on average, the teacher planned %{baseline}",
      value: duration(signal.value),
      baseline: duration(signal[:baseline])
    )
  end

  defp note(%{key: key, basis: :group} = signal) when key in [:fast_dwell, :slow_dwell] do
    gettext("%{value} on average, the group usually spends %{baseline} (%{peers} students)",
      value: duration(signal.value),
      baseline: duration(signal[:baseline]),
      peers: signal[:peers]
    )
  end

  defp note(%{key: :shallow_scroll} = signal),
    do:
      gettext("read %{value} of the page on average (expected at least %{baseline}%)",
        value: percent_value(signal.value),
        baseline: signal[:baseline]
      )

  defp note(%{key: key} = signal)
       when key in [:heavy_paste, :video_skipped, :heavy_paste_on_exam] do
    gettext("%{value} of it, the limit is %{baseline}",
      value: share(signal.value),
      baseline: share(signal[:baseline])
    )
  end

  defp note(%{key: :hesitation, basis: :group} = signal),
    do:
      gettext("%{value} changes, most of the group made %{baseline} or fewer",
        value: signal.value,
        baseline: format_number(signal[:baseline])
      )

  defp note(%{key: :hesitation} = signal),
    do: gettext("%{value} changes of answer", value: signal.value)

  defp note(%{key: :backtracked} = signal),
    do:
      gettext("%{value} time(s) - usually a sign the material wasn't clear the first time",
        value: signal.value
      )

  defp note(%{key: :panic_debugging}),
    do: gettext("looks like guessing rather than fixing the code")

  defp note(%{key: :no_debug_cycle}),
    do: gettext("the solution was pasted and submitted as is")

  defp note(%{key: :excessive_tab_switching} = signal),
    do:
      gettext("%{value} times, the limit is %{baseline}",
        value: signal.value,
        baseline: signal[:baseline]
      )

  defp note(%{category: :integrity} = signal),
    do:
      gettext("%{value} time(s) - see the cheating monitor for details",
        value: signal[:value] || 1
      )

  defp note(%{key: :low_score, basis: :absolute} = signal) do
    case signal[:baseline] do
      nil ->
        gettext("below the pass mark of %{threshold}", threshold: signal[:threshold])

      median ->
        gettext("below the pass mark of %{threshold}; the group's median is %{median}",
          threshold: signal[:threshold],
          median: format_number(median)
        )
    end
  end

  defp note(%{key: :low_score} = signal),
    do:
      gettext("the group's median is %{median} (%{peers} students)",
        median: format_number(signal[:baseline]),
        peers: signal[:peers]
      )

  defp note(%{key: :many_attempts, basis: :group} = signal),
    do: gettext("the group usually needs %{baseline}", baseline: format_number(signal[:baseline]))

  defp note(%{key: :many_attempts}), do: gettext("many tries in a row usually means guessing")

  defp note(%{key: :missed_block} = signal),
    do: gettext("%{share} of the group has already completed it", share: share(signal[:baseline]))

  defp note(%{key: :behind_progress} = signal),
    do:
      gettext("%{value} of the course done, the group's median is %{baseline}",
        value: percent_value(signal.value),
        baseline: percent_value(signal[:baseline])
      )

  defp note(_signal), do: ""

  defp theory_lines(%{theory: theory}, block_names) when is_list(theory) do
    Enum.map(theory, fn review ->
      block = Map.get(block_names, review.block_id, gettext("a block"))

      case review.status do
        :skipped ->
          gettext("Theory before it: “%{block}” - never opened", block: block)

        :superficial ->
          gettext("Theory before it: “%{block}” - skimmed (%{how})",
            block: block,
            how: review.flags |> Map.keys() |> Enum.map_join(", ", &skim_label/1)
          )

        :ok ->
          gettext("Theory before it: “%{block}” - studied normally", block: block)
      end
    end)
  end

  defp theory_lines(_signal, _block_names), do: []

  defp skim_label(:fast_dwell), do: gettext("too fast")
  defp skim_label(:shallow_scroll), do: gettext("not read to the end")
  defp skim_label(:video_skipped), do: gettext("video skipped")

  @doc "How a student went through one theory block, in a few words."
  @spec theory_status_label(map()) :: String.t()
  def theory_status_label(%{status: :skipped}), do: gettext("never opened")

  def theory_status_label(%{status: :superficial, flags: flags}),
    do:
      gettext("skimmed (%{how})", how: flags |> Map.keys() |> Enum.map_join(", ", &skim_label/1))

  def theory_status_label(%{status: :ok}), do: gettext("studied normally")

  @doc """
  One-sentence reading of a gradebook cell next to the theory in front of
  it: is a low score most likely about skipped theory, or about the topic?
  `cell` is a gradebook cell (or `nil` - not started), `reviews` the
  student's theory reviews for that task.
  """
  @spec cell_verdict(map() | nil, [map()], integer()) :: String.t()
  def cell_verdict(cell, reviews, threshold) do
    weak? = Enum.any?(reviews, &(&1.status in [:skipped, :superficial]))

    cond do
      is_nil(cell) and weak? ->
        gettext("Not started yet - and the theory in front of it hasn't been studied either.")

      is_nil(cell) ->
        gettext("Not started yet.")

      cell.state == :review ->
        gettext("Waiting for a teacher's grade.")

      cell.state == :in_progress ->
        gettext("Being checked right now.")

      cell.score < threshold and weak? ->
        gettext(
          "Most likely the topic wasn't learned: the theory in front of the task was skipped or skimmed."
        )

      cell.score < threshold and reviews == [] ->
        gettext("Below the pass mark. There is no theory in front of this task to compare with.")

      cell.score < threshold ->
        gettext(
          "The theory was studied, yet the task failed - the topic itself may be unclear; worth going through it together."
        )

      weak? ->
        gettext(
          "Passed even though the theory was skipped or skimmed - they may have known the topic already."
        )

      true ->
        gettext("Passed, with the theory studied normally.")
    end
  end

  @doc "Short name of a Course Map issue (`Athena.Engagement.CourseMap`)."
  @spec issue_label(atom()) :: String.t()
  def issue_label(:low_scores), do: gettext("Low scores")
  def issue_label(:many_attempts), do: gettext("Many attempts")
  def issue_label(:skimmed), do: gettext("Rushed through")
  def issue_label(:stuck), do: gettext("Students get stuck")
  def issue_label(:high_backtrack_rate), do: gettext("Students come back")
  def issue_label(:high_hesitation_rate), do: gettext("Answers keep changing")
  def issue_label(key), do: key |> to_string() |> String.replace("_", " ")

  @doc "One line about a Course Map issue, with its number."
  @spec issue_note(map()) :: String.t()
  def issue_note(%{key: :low_scores, value: share}),
    do: gettext("only %{share} reached the pass mark", share: share(share))

  def issue_note(%{key: :many_attempts, value: avg}),
    do:
      gettext("%{avg} attempts on average", avg: :erlang.float_to_binary(avg * 1.0, decimals: 1))

  def issue_note(%{key: :skimmed, value: share}),
    do: gettext("%{share} of those who opened it rushed through it", share: share(share))

  def issue_note(%{key: :stuck, value: share}),
    do: gettext("%{share} of those who opened it got stuck", share: share(share))

  def issue_note(%{key: :high_backtrack_rate, value: share}),
    do: gettext("%{share} came back to it after moving on", share: share(share))

  def issue_note(%{key: :high_hesitation_rate, value: share}),
    do: gettext("%{share} kept changing their answers", share: share(share))

  def issue_note(_issue), do: ""

  @doc "Human name of a block metric key (`Athena.Engagement.get_metrics/1`)."
  @spec metric_label(atom()) :: String.t()
  def metric_label(:sample_size), do: gettext("Visits measured")
  def metric_label(:avg_dwell_seconds), do: gettext("Average time, s")
  def metric_label(:dwell_ratio), do: gettext("Time vs. planned")
  def metric_label(:students_observed), do: gettext("Students")
  def metric_label(:tab_hidden_count), do: gettext("Tab switches")
  def metric_label(:avg_time_to_first_action), do: gettext("Time to first action, s")
  def metric_label(:offtask_ratio), do: gettext("Share of time in other tabs")
  def metric_label(:backtrack_count), do: gettext("Came back after moving on")
  def metric_label(:backtrack_rate), do: gettext("Share who came back")
  def metric_label(:hesitation_rate), do: gettext("Share who changed answers")
  def metric_label(:avg_scroll_depth_percent), do: gettext("Scrolled, %")
  def metric_label(:play_count), do: gettext("Plays")
  def metric_label(:pause_count), do: gettext("Pauses")
  def metric_label(:seek_count), do: gettext("Rewinds")
  def metric_label(:completion_count), do: gettext("Watched to the end")
  def metric_label(:skip_ratio), do: gettext("Share skipped")
  def metric_label(:paste_ratio), do: gettext("Share pasted")
  def metric_label(:answer_change_count), do: gettext("Answer changes")
  def metric_label(:focus_loss_count), do: gettext("Left the exam tab")
  def metric_label(:focus_loss_seconds), do: gettext("Time away from the exam, s")
  def metric_label(:window_blur_count), do: gettext("Window lost focus")
  def metric_label(:printscreen_count), do: gettext("Screenshot attempts")
  def metric_label(:copy_attempt_count), do: gettext("Copy attempts")
  def metric_label(:cut_attempt_count), do: gettext("Cut attempts")
  def metric_label(:multi_tab_count), do: gettext("Opened in several tabs")
  def metric_label(:idle_seconds_total), do: gettext("Idle time, s")
  def metric_label(:exam_paste_ratio), do: gettext("Share pasted")
  def metric_label(:exam_answer_change_count), do: gettext("Answer changes")
  def metric_label(:exam_run_attempt_count), do: gettext("Code runs")
  def metric_label(:exam_panic_debugging?), do: gettext("Rapid re-runs")
  def metric_label(:run_attempt_count), do: gettext("Code runs")
  def metric_label(:debug_cycle_present?), do: gettext("Ran the code")
  def metric_label(:panic_debugging?), do: gettext("Rapid re-runs")
  def metric_label(:open_count), do: gettext("Opens")
  def metric_label(:unique_openers), do: gettext("Students who opened")
  def metric_label(:zoom_count), do: gettext("Zooms")
  def metric_label(key), do: key |> to_string() |> String.replace("_", " ")

  # Recommendations

  @doc """
  What a teacher can do, most urgent first, at most `limit` lines - one per
  kind of problem, naming the exact blocks.
  """
  @spec recommendations([map()], map(), pos_integer()) :: [String.t()]
  def recommendations(signals, block_names, limit \\ 4) do
    name = &Map.get(block_names, &1, gettext("a block"))
    by_key = Enum.group_by(signals, & &1.key)
    first = fn key -> by_key |> Map.get(key, []) |> List.first() end

    [
      first.(:inactive) &&
        gettext("Reach out personally: they haven't opened the course during this period."),
      Enum.find(signals, &(&1.category == :integrity)) &&
        gettext("Review the flagged exam attempt in the cheating monitor before grading it."),
      weak_theory_advice(Map.get(by_key, :low_score, []), name),
      first.(:many_attempts) &&
        gettext("Look at the attempts on “%{block}”: many quick retries usually mean guessing.",
          block: name.(first.(:many_attempts).block_id)
        ),
      missed_advice(Map.get(by_key, :missed_block, []), first.(:behind_progress), name),
      Enum.find(signals, &(&1.category == :slacking)) &&
        gettext("Talk about pace: they go through the material much faster than the group."),
      struggle_advice(Enum.filter(signals, &(&1.category == :struggling)), name)
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.take(limit)
  end

  # A low score after skipped or skimmed theory points at the theory; a low
  # score after theory studied properly points at the topic itself.
  defp weak_theory_advice([], _name), do: nil

  defp weak_theory_advice(low_scores, name) do
    weak =
      for signal <- low_scores,
          review <- Map.get(signal, :theory, []),
          review.status in [:skipped, :superficial],
          uniq: true,
          do: review.block_id

    case weak do
      [] ->
        gettext(
          "Go through “%{block}” together: the theory was studied, but the task still failed - the topic itself may be unclear.",
          block: name.(hd(low_scores).block_id)
        )

      blocks ->
        gettext(
          "Ask them to go back to %{blocks}: it was skipped or skimmed before the task they failed.",
          blocks: blocks |> Enum.take(2) |> Enum.map_join(", ", &"“#{name.(&1)}”")
        )
    end
  end

  defp missed_advice([], nil, _name), do: nil

  defp missed_advice([], _behind, _name),
    do: gettext("Check in on their pace: they are well behind the group in the course.")

  defp missed_advice(missed, _behind, name) do
    gettext("Remind them about what they skipped: %{blocks}.",
      blocks: missed |> Enum.take(3) |> Enum.map_join(", ", &"“#{name.(&1.block_id)}”")
    )
  end

  defp struggle_advice([], _name), do: nil

  defp struggle_advice([signal | _], name),
    do:
      gettext("Offer help with “%{block}”: they get stuck there more than others.",
        block: name.(signal.block_id)
      )

  # Formatting

  @doc "Seconds as a short human duration: \"45 s\", \"4 min\", \"1 h 5 min\"."
  @spec duration(number() | nil) :: String.t()
  def duration(nil), do: "—"

  def duration(seconds) do
    seconds = round(seconds)

    cond do
      seconds < 60 -> gettext("%{n} s", n: seconds)
      seconds < 3600 -> gettext("%{n} min", n: round(seconds / 60))
      true -> gettext("%{h} h %{m} min", h: div(seconds, 3600), m: rem(div(seconds, 60), 60))
    end
  end

  defp share(nil), do: "—"
  defp share(ratio), do: "#{round(ratio * 100)}%"

  defp percent_value(nil), do: "—"
  defp percent_value(value), do: "#{round(value)}%"

  defp format_number(nil), do: "—"
  defp format_number(value) when is_float(value), do: value |> round() |> Integer.to_string()
  defp format_number(value), do: to_string(value)
end
