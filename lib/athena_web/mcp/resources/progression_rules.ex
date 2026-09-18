defmodule AthenaWeb.MCP.Resources.ProgressionRules do
  @moduledoc """
  Static MCP resource documenting `access_rules` (time-locks / "waterline"),
  `completion_rule` (how a student unlocks the next block), and
  `engagement_rule` (time-on-block nudge thresholds) - the three embedded
  rule fields on `Athena.Content.Section`/`Athena.Content.Block` that
  `create_section`/`update_section`/`create_block`/`update_block` accept
  alongside `content`.

  Source of truth: `Athena.Content.AccessRules`, `Athena.Content.CompletionRule`
  (file `competition_rule.ex` - legacy filename typo, module name is correct),
  `Athena.Content.EngagementRule`, `Athena.Content.Policy`,
  `Athena.Learning.Progress`, `AthenaWeb.LearnLive.Player`.
  """

  @behaviour EMCP.Resource

  @markdown_content """
  # Progression rules: access_rules, completion_rule, engagement_rule

  These are optional embedded objects you can pass alongside `content` to
  `create_section`/`update_section` (`access_rules`, `engagement_rule`) and
  `create_block`/`update_block` (`access_rules`, `completion_rule`,
  `engagement_rule` - `completion_rule` is block-only, sections don't have one).
  Like `content` on `update_block`/`update_section`, each of these REPLACES
  the whole embedded object - there is no field-level merge.

  ## access_rules - time locks ("waterline")

  ```json
  {"unlock_at": "2026-01-01T00:00:00Z", "lock_at": null, "reset_waterline": false}
  ```

  - `unlock_at` (ISO-8601 datetime string, optional): item is invisible before this time.
  - `lock_at` (ISO-8601 datetime string, optional): item is invisible from this time onward.
    If both are set, `lock_at` must be strictly after `unlock_at`.
  - `reset_waterline` (boolean, default `false`): see "The waterline" below.

  **`access_rules` only has any effect when the section/block's `visibility`
  is `"restricted"`.** `"enrolled"` is always visible (once enrolled) and
  ignores `access_rules` entirely; `"hidden"` is never visible; `"inherit"`
  (blocks only) defers to the parent section's visibility. Setting
  `access_rules` on an `"enrolled"`/`"hidden"` item is accepted but has no
  runtime effect - set `visibility: "restricted"` too if you want the dates
  enforced.

  ### The waterline

  Athena enforces progression as a single monotonic "high-water mark" down a
  linear list (sections within a course, or blocks within a section), not
  per-item unlock puzzles. Walking that list in order: any block whose
  `completion_rule.type` is not `"none"` is a **gate**. The moment the walk
  hits a gate the student hasn't completed yet, every section/block after it
  is hidden - this is the waterline. A later, otherwise-eligible item cannot
  be reached by unlocking it individually; the gate in front of it must be
  cleared first.

  `reset_waterline: true` on a section (or, within a section's own block
  list, on a block) punches a fresh checkpoint through that wall: that
  specific item becomes visible regardless of any uncompleted gate earlier
  in the course, and the `blocked?` accumulator restarts from that point
  (gates after it still work normally). It does **not** retroactively
  unlock anything before it, and it does **not** clear/reset any student's
  already-recorded completions - "reset" means "reset the lock-propagation
  checkpoint here," not "reset a student's progress."

  Practical recipe: to make a section always reachable regardless of earlier
  incomplete work (e.g. a "final project" intro, or a bonus unit), set
  `access_rules: {"reset_waterline": true}` on it (visibility can stay
  `"enrolled"` for this to matter for the *waterline*, but remember
  `unlock_at`/`lock_at` themselves still require `"restricted"` to be enforced).

  `unlock_at`/`lock_at` are independent of the waterline - they're an
  absolute calendar gate (e.g. "don't reveal week 3 before March 1st")
  layered on top of it, checked via `Athena.Content.Policy.can_view?/4`
  wherever visibility is `"restricted"`.

  ## completion_rule (block only)

  ```json
  {"type": "button", "button_text": "Continue", "min_score": null}
  ```

  - `type`: `"none"` (default) | `"button"` | `"submit"` | `"pass_auto_grade"`.
  - `button_text` (string): required if and only if `type == "button"`; ignored/nulled otherwise.
  - `min_score` (integer 0-100): required if and only if `type == "pass_auto_grade"`; ignored/nulled otherwise.

  `type` is what makes a block a **gate** in the waterline sense (see
  above) - `"none"` is not a gate at all: students scroll past it freely,
  no button, no submission required, nothing blocks progression on it.

  ### What each type actually does for the student

  - **`"none"`**: not a gate. Purely informational/practice content.
  - **`"button"`**: a "Continue" button (custom text via `button_text`,
    Yandex-Praktikum-style "I understand, next") appears under the block;
    clicking it completes the gate immediately - no correctness check of any
    kind, just the click.
  - **`"submit"`**: the gate is satisfied by ANY submission at all,
    regardless of correctness/score - "attempted it" is enough. This is the
    only mode that makes sense for `file_assignment` (student uploads
    file(s) and clicks submit - there's nothing to auto-grade), and is also
    a valid, deliberately-lenient choice for `code`/`quiz_question`/
    `quiz_exam`/`ticket_exam` if you want "tried it" rather than "got it right."
  - **`"pass_auto_grade"`**: requires an auto-graded submission scoring
    `>= min_score` before the gate opens - wrong/low-scoring attempts do not
    unlock what comes next; the student can keep retrying (subject to the
    block's own `max_attempts`, if any).

  ### Which `type`s make sense per block `type`

  The Studio UI restricts the offered choices per block type (the schema
  itself doesn't enforce this - it's a content-authoring convention worth
  following since `"pass_auto_grade"` on a `text` block has nothing to grade):

  | block `type` | sensible `completion_rule.type` values |
  |---|---|
  | `text`, `image`, `video`, `attachment` | `"none"`, `"button"` |
  | `file_assignment` | `"none"`, `"submit"` |
  | `code`, `quiz_question`, `quiz_exam`, `ticket_exam` | `"none"`, `"submit"`, `"pass_auto_grade"` |

  ## engagement_rule (time-on-block nudge thresholds)

  ```json
  {"expected_seconds": 300, "nudge_enabled": true, "fast_ratio_threshold": 0.4}
  ```

  Minor/optional compared to the two above - controls the "you're moving
  unusually fast" nudge shown to students, resolved as a block > section >
  app-default cascade (`Athena.Content.Policy.resolve_engagement_rule/2`).

  - `expected_seconds` (integer > 0): how long this block is expected to
    take. `null`/omitted = inherit from the section, then from app config.
  - `nudge_enabled` (boolean): `null`/omitted = inherit (this is NOT the
    same as `false` - `false` is a meaningful explicit opt-out, `null` means
    "use whatever the section/app default says").
  - `fast_ratio_threshold` (float in `(0, 1]`): a student spending less than
    `expected_seconds * fast_ratio_threshold` on the block is flagged as
    "suspiciously fast." `null`/omitted = inherit, ultimately defaulting to `0.4`.

  This has no effect on progression/locking - it only affects an
  engagement-analytics nudge shown to the student, unrelated to
  `completion_rule`/`access_rules`.
  """

  @impl EMCP.Resource
  def uri, do: "athena://docs/progression-rules"

  @impl EMCP.Resource
  def name, do: "progression_rules"

  @impl EMCP.Resource
  def description,
    do:
      "How access_rules (time-locks / \"waterline\"), completion_rule (button / submit / " <>
        "pass_auto_grade gates), and engagement_rule work on sections and blocks. Read this " <>
        "before setting any of those fields on create_section/update_section/create_block/update_block."

  @impl EMCP.Resource
  def mime_type, do: "text/markdown"

  @impl EMCP.Resource
  def read(_conn), do: @markdown_content
end
