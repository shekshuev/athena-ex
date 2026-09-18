defmodule AthenaWeb.MCP.Resources.LibraryAndExams do
  @moduledoc """
  Static MCP resource documenting reusable library content
  (`create_library_block`/`list_library_blocks`/`pin_library_block`) and the
  exact question-pool mechanics behind `quiz_exam`/`ticket_exam` blocks -
  most importantly, that both pull EXCLUSIVELY from library blocks pinned
  to the specific course, never from the account's whole library.

  Source of truth: `Athena.Content.Library.generate_exam_questions/2`,
  `generate_ticket_questions/3`, `pin_library_block/3` (in `Courses`).
  """

  @behaviour EMCP.Resource

  @markdown_content """
  # Library blocks, pinning, and quiz_exam / ticket_exam pools

  ## Reusing content via the library

  A `LibraryBlock` is content (same `type`/`content` shapes as a regular
  block - see `athena://docs/block-content-schemas`) that isn't tied to any
  one course. Workflow:

  1. `create_library_block` - make a reusable `quiz_question`/`code`/
     `file_assignment`/etc. block, owned by you, with `tags` (array of
     strings) for later matching.
  2. `list_library_blocks` - browse what already exists before creating a
     duplicate. Pass `course_id` + `pinned_only: true` to see exactly
     what's already pinned to a given course; omit `pinned_only` to search
     your whole library (optionally filtered with `tag_search`, a
     comma-separated substring match against tags).
  3. `pin_library_block` - attach an existing library block to a specific
     course's "workspace." **This is the step that makes it eligible for
     that course's `quiz_exam`/`ticket_exam` blocks** (see below) - owning
     or being able to edit a library block is NOT enough on its own.

  Pinning is course-specific: the same library block can be pinned to
  several different courses independently, and unpinning it from one
  course doesn't affect the others or delete the block itself.

  ## quiz_exam / ticket_exam: where their questions actually come from

  **The candidate pool for both is ALWAYS restricted to library blocks of
  type `quiz_question`, `code`, or `file_assignment` that are pinned to
  THIS SPECIFIC course** (via `pin_library_block`) - never "any block the
  account owns," never "the global library," never other courses' pinned
  blocks. A block you can freely edit but haven't pinned to this course
  will never appear in this course's generated exam/ticket, no matter how
  permissive its sharing settings are. This is looked up live every time a
  student takes the exam/ticket (the exam/ticket block's own `content`
  only stores the *rules* for selection - `tags`/`slots`/`count` - not the
  actual questions; they're assembled fresh, ephemerally, from whatever is
  pinned at that moment).

  Practical consequence for course authoring: **before creating a
  `quiz_exam`/`ticket_exam` block with a given set of tags, make sure
  enough matching library blocks are already pinned to that course** -
  otherwise the exam will silently produce fewer questions than `count`
  asks for (no error is raised for an under-filled pool).

  ### quiz_exam content shape and matching

  ```json
  {
    "count": 10,
    "time_limit": 900,
    "allowed_blur_attempts": 3,
    "mandatory_tags": ["sql"],
    "include_tags": [],
    "exclude_tags": [],
    "slots": []
  }
  ```

  Two mutually exclusive modes, chosen by whether `slots` is a non-empty list:

  - **No `slots` (legacy tag-rule mode)**: pulls up to `count` random
    pinned candidates whose `tags` OVERLAP (at least one tag in common,
    not all) `mandatory_tags`, excluding any that overlap `exclude_tags`.
    If that doesn't fill `count`, tops up the remainder from candidates
    overlapping `include_tags` (again excluding `exclude_tags` and
    anything already picked). An empty `mandatory_tags`/`include_tags`
    list matches nothing (not "everything") - you must specify real tags.
  - **With `slots`** (e.g. `[{"id": "s1", "count": 2, "tags": ["easy"]}]`):
    each slot independently picks `count` (default 1) random candidates
    whose `tags` array contains **ALL** of that slot's `tags` (subset
    match, stricter than the legacy mode's overlap match), never reusing a
    candidate another slot in the same exam already claimed. `id` just
    needs to be unique within the `slots` list.

  ### ticket_exam content shape and matching

  ```json
  {"time_limit": 1800, "allowed_blur_attempts": 3, "slots": [{"id": "s1", "tags": ["sql"]}]}
  ```

  Always slot-based (no legacy tag-rule mode) and exactly **one** block per
  slot (no `count` per slot). Same ALL-match tag rule as quiz_exam's slot
  mode. Additionally biases slot selection toward whichever pinned
  candidate has been used least often in that specific student's ticket
  history so far, so repeat attempts don't keep drawing the same ticket -
  this bias is entirely automatic, nothing to configure.

  ## Summary

  | | quiz_exam | ticket_exam |
  |---|---|---|
  | Pool source | library blocks pinned to this course | library blocks pinned to this course |
  | Eligible library block types | `quiz_question`, `code`, `file_assignment` | same |
  | Legacy (no-slots) mode | yes, `mandatory_tags`/`include_tags`/`exclude_tags` | no, always slot-based |
  | Slot tag match | ALL of slot's tags present on block | ALL of slot's tags present on block |
  | Questions per slot | `count` (can be > 1) | exactly 1 |
  | Repeat-attempt behavior | independent random draw each time | biased toward least-used candidate |
  """

  @impl EMCP.Resource
  def uri, do: "athena://docs/library-and-exams"

  @impl EMCP.Resource
  def name, do: "library_and_exams"

  @impl EMCP.Resource
  def description,
    do:
      "How to reuse content via the library (create_library_block / list_library_blocks / " <>
        "pin_library_block), and the exact quiz_exam/ticket_exam question-pool rules - most " <>
        "importantly that both draw ONLY from library blocks pinned to that specific course."

  @impl EMCP.Resource
  def mime_type, do: "text/markdown"

  @impl EMCP.Resource
  def read(_conn), do: @markdown_content
end
