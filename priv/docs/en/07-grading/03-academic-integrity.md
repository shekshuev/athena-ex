%{
  title: "Academic integrity",
  description: "How the risk of dishonest behaviour during an assessment is evaluated and what the teacher does."
}
---
## Purpose

During assessments and ticket assessments the student's browser reports actions that may indicate dishonest behaviour: leaving the page, attempts to copy the question, pasting ready-made text and others. The system adds them up into **risk points** and gives the attempt one of three levels. The decision about a violation is always the teacher's; the automatic level only points to attempts worth a look.

## Risk levels

| Level | Points (default) | Label |
|---|---|---|
| Green | below 2 | :ui[No violations] |
| Yellow | 2 to 3 | :ui[Some violations] |
| Red | 4 or more | :ui[High risk] |

Points, rather than "any signal makes it yellow", let several weak signs add up without accidentally reaching red, while one strong sign can be enough on its own.

## What earns points

### Direct evidence

Counted as they are, **2 points for each occurrence**, without comparison with other students: during a locked-down question view there is no legitimate reason for them.

| Sign | Condition |
|---|---|
| :ui[Screenshot attempt] | The PrintScreen key was pressed (Windows only) |
| :ui[Copy / cut attempt] | An attempt to copy or cut the question text. The action itself is blocked; the sign means an attempt, not captured text |
| :ui[Multiple tabs] | The same attempt is open in another tab or window of the same browser |
| :ui[Large paste] | A single paste or drag-and-drop of 150 or more characters into an answer |
| :ui[Text inserted without typing] | A large piece of text appeared in an answer without typing, paste or drag-and-drop, for example written by a browser extension |

### Time away from the assessment

Hiding the tab, losing window focus and leaving fullscreen are merged into **absences**; overlapping intervals count as one absence. An absence counts as significant if it lasted at least 10 seconds.

| Condition | Points |
|---|---|
| At least one significant absence | 2 (yellow) |
| 3 or more significant absences, **or** at least 60 seconds away in total | 4 (red) |

There is no allowed number of absences: they are judged by frequency and duration.

The mouse pointer leaving the window and a window sharing the screen with another one are also recorded: this catches reading a neighbouring window without losing focus. Split screen gives 1 point for one occurrence and 2 points for several.

### Telemetry silence

During an attempt the browser regularly signals the server. If no signal arrives for longer than usual, or the browser reports being offline, the gap itself is suspicious: tracking may have been disabled, or the connection lost.

| Longest gap | Points |
|---|---|
| from 45 seconds | 2 (yellow) |
| from 120 seconds | 4 (red) |

The longest gap is kept for the whole attempt and does not clear when reporting resumes.

> [!WARNING]
> A red level from telemetry silence can also mean an ordinary browser crash or a lost connection. Contact the student before treating it as a violation.

### Typing patterns

Only totals are collected: which keys were pressed, and when, is not stored. On-screen keyboards, dictation and other composition input are excluded.

| Sign | Condition | Points |
|---|---|---|
| Machine-like typing rhythm | At least 50 key presses with an average key-hold time of 5 ms or less (a macro or keystroke emulator) | 2 |
| Long answer without corrections | At least 500 characters typed, less than 1% deleted | 1 |

### Behaviour compared to the group

For the following indicators a raw count means nothing: an anxious student who changes answers many times looks, by the numbers, like one who cheats. So the indicator is compared with what **the other students taking the same assessment in the same group** do.

| Indicator | Points | Floor | Fixed limit | Minimum events |
|---|---|---|---|---|
| Switching away, per minute | 1 | 0.2 | 1.0 | 3 |
| Pasted text ratio | 2 | 0.2 | 0.8 | – |
| Answer changes, per minute | 1 | 0.5 | 3.0 | 5 |
| Right-clicks, per minute | 1 | 0.2 | 1.0 | 2 |
| Seconds of pointer outside the window, per minute | 1 | 3 | 15 | 20 s |

Per-minute indicators are not evaluated during the first 3 minutes of an attempt and must rest on the stated minimum of actual events. The pasted text ratio is not counted if a large paste was already counted, so that one event never earns points twice.

The **group baseline** for a student is the median of the other participants' values and their spread (scaled median absolute deviation). The student's own value is not part of their baseline. Students who already handed in stay in the comparison, so the group's size does not depend on the order of submission.

An indicator counts by the first rule that applies:

1. The value is at least **twice the fixed limit** – it counts whatever the group does.
2. There are at least **2 other participants** – it counts if the value reaches the group threshold. The group threshold is the largest of:
   - the indicator's floor;
   - the group median × 3;
   - the group median + 3 × spread;
   - with fewer than 8 other participants – half the fixed limit (a small group can raise the bar, never lower it below this line).
3. There is nobody to compare with – it counts if the value reaches the fixed limit.

## Where it shows

### An answer in the grading center

1. Open :ui[Teaching] › :ui[Assignments].
2. Open an assessment answer with :ui[Grade] or :ui[View].
3. In the right panel, find the :ui[Academic Integrity] section.

The section shows:

- the risk level badge, or the teacher's decision if one has been made (the automatic level is then shown in the badge's tooltip);
- the number of direct evidence items and the number of indicators with unusual behaviour;
- the :ui[Learn more] button, which opens the :ui[Why this submission was flagged] window.

### The "Why this submission was flagged" window

The window has two tabs.

**:ui[Summary]**:

- total points and the attempt's duration;
- the :ui[Teacher review] form (see below);
- :ui[What counted] – each sign that earned points, with its value and basis: "others usually …, the bar was …", "above the fixed limit of …" and so on;
- :ui[Everything measured] – every measured indicator, including those that earned no points, next to the usual value of the others.

**:ui[Timeline]**: every event of the attempt by time from its start: leaving the page and for how long, pastes with character counts, copy attempts, connection gaps, window size changes.

> [!NOTE]
> For attempts rated by an earlier version of the check, the window shows a notice: counters may read zero even though the timeline shows activity. In that case rely on the :ui[Timeline].

### The teacher's decision

In the :ui[Teacher review] form on the :ui[Summary] tab:

1. Optionally fill in :ui[Note (optional)].
2. Click :ui[Confirm violation] or :ui[Reviewed - no violation].

The decision is saved with the answer (who made it and when), and every recorded sign stays unchanged. The decision affects other screens as follows:

| Screen | :ui[Confirm violation] | :ui[Reviewed - no violation] |
|---|---|---|
| Badge in the grading center | :ui[Violation confirmed] | :ui[Reviewed - no violation] |
| Diamond in the gradebook ([engagement layer](/docs/engagement/gradebook-layer)) | Red | Not shown |
| :ui[Attempts flagged by the cheating monitor] in the [group comparison](/docs/engagement/compare-groups) | Counted | Not counted |
| :ui[Integrity] signals on the [group radar](/docs/engagement/group-radar) | Unchanged | Unchanged |

Signals on the group radar follow simplified absolute rules (see the [Signals reference](/docs/engagement/signals#integrity)) and are not removed by the teacher's decision: the radar shows recorded behaviour.

### The cheating monitor

The monitor shows the risk of every participant of one assessment in the group in real time.

1. Open :ui[Teaching] › :ui[Assignments].
2. In the row of an assessment answer, click the shield button :ui[Monitor this group for cheating].

On the :ui[Cheating Monitor] screen each student of the group has a :ui[Risk] (updated as the attempt goes on), the attempt's :ui[Status] and an :ui[Open] link to the answer. Students who have not started are marked :ui[Not started]. The :ui[Learn more] button opens the :ui[How the cheating risk indicator is calculated] window with every sign and the current thresholds.

## Known blind spots

- The system sees only what a browser can observe. A second device (such as a phone) is not detected.
- Screenshots taken with macOS shortcuts, Win+Shift+S or third-party tools are not detected.
- A second tab is detected only in the same browser and the same profile.
- A lost connection or a browser crash looks the same as disabled tracking.

## Thresholds

| Key | Default | Meaning |
|---|---|---|
| `exam_risk_yellow_points` | 2 | Points for yellow |
| `exam_risk_red_points` | 4 | Points for red |
| `exam_large_paste_chars` | 150 | Characters in a single paste for a large paste |
| `exam_away_incident_min_seconds` | 10 | Minimum duration of a significant absence, s |
| `exam_away_red_incidents` | 3 | Significant absences for red |
| `exam_away_red_seconds` | 60 | Total time away for red, s |
| `exam_heartbeat_silence_yellow_threshold_seconds` | 45 | Telemetry gap for yellow, s |
| `exam_heartbeat_silence_red_threshold_seconds` | 120 | Telemetry gap for red, s |
| `exam_min_minutes_for_rates` | 3 | Minutes of an attempt before per-minute indicators are evaluated |
| `exam_min_baseline_peers` | 2 | Minimum other participants for group comparison |
| `exam_trusted_group_peers` | 8 | Number of other participants from which the group is trusted |
| `exam_baseline_ratio` | 3 | Median multiplier in the group threshold |
| `exam_baseline_spread` | 3 | Spread multiplier in the group threshold |
| `exam_small_group_fallback_share` | 0.5 | Share of the fixed limit below which a small group cannot lower the threshold |
| `exam_extreme_factor` | 2 | How many times the limit counts regardless of the group |
| `exam_machine_typing_min_keys` | 50 | Minimum key presses to judge a machine-like rhythm |
| `exam_machine_typing_max_dwell_ms` | 5 | Average key-hold time for a machine-like rhythm, ms |
| `exam_clean_typing_min_chars` | 500 | Minimum characters typed for the "no corrections" sign |
| `exam_clean_typing_max_correction_ratio` | 0.01 | Share of deleted characters below which an answer counts as typed without corrections |

Thresholds are set in the `config :athena, Athena.Engagement` section of `config/config.exs`. Floors, fixed limits and minimum events of the behaviour indicators can be overridden with the `exam_metric_floors`, `exam_metric_fallbacks` and `exam_metric_min_totals` keys.
