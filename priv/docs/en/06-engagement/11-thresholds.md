%{
  title: "Thresholds reference",
  description: "Every configurable threshold and its default value."
}
---
## Where they are set

The module's thresholds are set in the application configuration, in the `config :athena, Athena.Engagement` section of `config/config.exs`. Changing a threshold requires restarting the application and applies to every course and group. Thresholds cannot be changed in the interface; per section and block only the expected time, the fast-completion threshold and allowing nudges are configurable (see [Settings and nudges](/docs/engagement/settings-nudges)).

Shares are numbers from 0 to 1, percentages are numbers from 0 to 100.

## Block defaults

| Key | Default | Meaning |
|---|---|---|
| `default_expected_seconds` | not set | A block's expected time when neither the block nor its section sets one |
| `default_fast_ratio_threshold` | 0.4 | Fast-completion threshold for the nudge |

## Nudges

| Key | Default | Meaning |
|---|---|---|
| `min_sample_size_for_percentile` | 15 | How many time measurements on a block the group needs before the nudge decision uses the group's distribution |
| `min_scroll_percent_for_text` | 70 | Visible share of a text block (%) below which the nudge is shown and :ui[Doesn't read to the end] fires |
| `paste_ratio_nudge_threshold` | 0.8 | Pasted share above which the nudge is shown and :ui[Pastes answers] fires |
| `video_skip_ratio_threshold` | 0.3 | Skipped share of a video above which the nudge is shown and :ui[Skips video] fires |

The "bottom 10%" boundary of the distribution for the fast-completion nudge is fixed and not configurable.

## Behaviour signals

| Key | Default | Meaning |
|---|---|---|
| `min_group_for_baseline` | 5 | Minimum students with data before the group comparison is made (medians, percentiles) |
| `concern_dwell_ratio_threshold` | 0.5 | :ui[Too fast] with an expected time: time < threshold × expected |
| `slow_dwell_ratio_threshold` | 2.0 | :ui[Very slow] with an expected time: time > threshold × expected |
| `group_fast_dwell_ratio` | 0.4 | :ui[Too fast] without an expected time: time < threshold × group median |
| `group_slow_dwell_ratio` | 2.5 | :ui[Very slow] without an expected time: time > threshold × group median |
| `hesitation_min_changes` | 2 | Minimum answer changes for :ui[Changes answers] |
| `hesitation_group_percentile` | 0.8 | Group percentile to exceed for :ui[Changes answers] |
| `hesitation_absolute_changes` | 3 | :ui[Changes answers] threshold without a group baseline |
| `panic_debug_gap_seconds` | 10 | Gap between code runs that counts as "rapid" |
| `panic_debug_min_bursts` | 3 | How many rapid gaps are needed for :ui[Re-runs code] |
| `no_debug_paste_ratio` | 0.5 | Pasted share of code from which an unrun solution gives :ui[Doesn't run code] |
| `concern_backtrack_rate_threshold` | 0.4 | :ui[Students come back] on the course map |
| `concern_hesitation_rate_threshold` | 0.4 | :ui[Answers keep changing] on the course map |
| `exam_focus_loss_threshold` | 3 | Times leaving the assessment page for the frequent-leaving signal |
| `exam_paste_ratio_threshold` | 0.6 | Pasted share in an assessment for the pasted-answers signal |

## Results and progress

| Key | Default | Meaning |
|---|---|---|
| `low_score_threshold` | 50 | The pass mark for every rule of the module |
| `low_score_group_gap` | 30 | How far below the group's median a score counts as low regardless of the pass mark |
| `many_attempts_min` | 3 | Minimum attempts for :ui[Many attempts] |
| `many_attempts_group_factor` | 2 | How many times the attempts must exceed the group's median |
| `not_mastering_min_low_scores` | 2 | How many low scores give the :ui[Not mastering the material] status |
| `behind_progress_gap` | 20 | Gap from the group's median progress (points) for :ui[Behind the group] |
| `missed_block_group_share` | 0.6 | Share of the group that completed a block for it to count as "completed by most" |
| `missed_blocks_for_behind` | 5 | Minimum skipped blocks for the :ui[Falling behind] status |
| `missed_blocks_share` | 0.1 | Minimum share of skipped blocks among those completed by most |

## Patterns and statuses

| Key | Default | Meaning |
|---|---|---|
| `pattern_min_blocks` | 3 | Minimum blocks with signals for the :ui[Skimming] and :ui[Struggling] statuses |
| `pattern_block_share` | 0.25 | Minimum share of such blocks among the opened ones |
| `pattern_group_factor` | 2 | How many times the share must exceed the group's median |
| `student_radar_integrity_threshold` | 1 | How many :ui[Integrity] signals give the :ui[Integrity risk] status |
| `student_radar_default_window_days` | 7 | The screens' default period, in days |

## Course map

| Key | Default | Meaning |
|---|---|---|
| `map_min_students` | 3 | How many students must stand behind a figure for a block to become a problem spot |
| `map_low_pass_share` | 0.6 | Share who passed below which :ui[Low scores] is raised |
| `map_critical_pass_share` | 0.4 | Share who passed below which :ui[Low scores] is critical |
| `map_attempts_avg` | 2.5 | Average attempts for :ui[Many attempts] on the map |
| `map_behaviour_share` | 0.4 | Share of openers with signals for :ui[Rushed through] and :ui[Students get stuck] |

## Processing and display

| Key | Default | Meaning |
|---|---|---|
| `dashboard_cache_ttl_ms` | 60 000 | How long a computed screen is kept, ms; 0 turns the cache off |
| `histogram_buckets` | 10 | Number of bars in the :ui[Dwell distribution] histogram |
| `histogram_max_seconds` | 1200 | Upper bound of the histogram, s |
| `block_stats_idle_timeout_minutes` | 30 | Minutes without events after which a block's nudge statistics are unloaded from memory |

How often the pre-aggregation job runs is set by the `ENGAGEMENT_ROLLUP_CRON` environment variable (every 5 minutes by default).

## Academic integrity

Keys prefixed `exam_` (except the two listed under "Behaviour signals") drive the risk indicator of assessment attempts. They are described in [Academic integrity](/docs/grading/academic-integrity).

## Obsolete keys

`student_radar_slacking_threshold` and `student_radar_struggling_threshold` belong to the radar's former colour scheme and do not affect the current statuses.
