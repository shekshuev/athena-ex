defmodule AthenaWeb.MCP.Resources.BlockContentSchemas do
  @moduledoc """
  Static MCP resource documenting the exact `content` shape for every
  `Athena.Content.Block`/`LibraryBlock` `type`, so an MCP agent building
  blocks (via `create_block`/`update_block`/`create_library_block`) never has
  to read Athena's source to guess a shape - especially the SQL code
  challenge, whose settings live nested inside `content.body` alongside the
  Tiptap task description rather than as their own top-level keys.

  Source of truth for each shape: the embedded changeset that validates it
  (`Athena.Content.CodeChallenge`, `QuizQuestion`, `QuizExam`, `TicketExam`,
  `FileAssignment`) plus, for the freeform types (`text`/`image`/`video`/
  `attachment`) with no embedded validation, the conventions the Studio
  Builder LiveView itself writes (`lib/athena_web/live/studio_live/builder.ex`).
  """

  @behaviour EMCP.Resource

  @markdown_content """
  # Block content shapes

  A block's `content` is a JSON object whose shape depends on `type`. Every
  rich-text field below (`body`, `description`, option/pair `text`) is a
  Tiptap/ProseMirror document, e.g.
  `{"type": "doc", "content": [{"type": "paragraph", "content": [{"type": "text", "text": "..."}]}]}`
  - a plain-text sentence in that form is always valid.

  Related resources: `athena://docs/progression-rules` (the separate
  `access_rules`/`completion_rule`/`engagement_rule` fields every block also
  accepts, alongside `content`) and `athena://docs/library-and-exams`
  (reusable library blocks, and exactly where `quiz_exam`/`ticket_exam`
  pull their questions from) and `athena://docs/media-uploads` (how to get
  a file onto S3 before referencing it from `image`/`video`/`attachment`/
  an inline Tiptap image).

  ## text

  `content` IS the Tiptap document directly (no wrapper key):

  ```json
  {"type": "doc", "content": [{"type": "paragraph", "content": [{"type": "text", "text": "Hello"}]}]}
  ```

  ## image

  ```json
  {"url": "https://.../file.png", "alt": "Diagram of the join order"}
  ```

  `url` must point at an already-uploaded file - see
  `athena://docs/media-uploads` for the `prepare_media_upload` ->
  (you PUT the bytes) -> `attach_media_to_block` flow. Create the block
  first with a placeholder (e.g. `{"url": null}`), then call
  `attach_media_to_block` once the file is uploaded.

  ## video

  ```json
  {"url": "https://.../video.mp4", "poster_url": "https://.../poster.png"}
  ```

  Same upload flow as `image` (`athena://docs/media-uploads`).

  ## attachment

  ```json
  {
    "files": [{"url": "https://.../handout.pdf", "name": "handout.pdf"}],
    "description": {"type": "doc", "content": [...]}
  }
  ```

  Same upload flow (`athena://docs/media-uploads`), but note `content.files`
  is a list - `attach_media_to_block` only ever sets a single `content.url`,
  so for `attachment` blocks you'll follow up with `update_block` to append
  each uploaded file's `{"url":..., "name":...}` into `files` yourself.

  ## file_assignment

  ```json
  {"max_files": 3, "body": {"type": "doc", "content": [...]}}
  ```

  `max_files` must be 1-20. `body` is the Tiptap description of what
  students must submit; the files themselves are uploaded by students later,
  not stored on the block.

  ## quiz_question

  ```json
  {
    "question_type": "single",
    "answer_type": "plain_text",
    "body": {"type": "doc", "content": [{"type": "paragraph", "content": [{"type": "text", "text": "What is 2+2?"}]}]},
    "options": [
      {"id": "<uuid>", "text": {"type": "doc", "content": [{"type": "paragraph", "content": [{"type": "text", "text": "4"}]}]}, "is_correct": true},
      {"id": "<uuid>", "text": {"type": "doc", "content": [{"type": "paragraph", "content": [{"type": "text", "text": "5"}]}]}, "is_correct": false}
    ],
    "max_attempts": 3,
    "general_explanation": "Basic arithmetic."
  }
  ```

  - `question_type`: `"single" | "multiple" | "exact_match" | "open" | "matching"`.
  - `answer_type`: `"plain_text" | "rich_text"`.
  - Required always: `question_type`, `body`.
  - `single`/`multiple`: use `options` (list of `{id, text, is_correct, explanation?}`,
    `id` any unique string).
  - `exact_match`: also requires a top-level `correct_answer` string;
    `case_sensitive` (bool, default false) controls matching.
  - `matching`: requires `pairs` (list of `{id, left, right}`, at least 2 entries,
    `left`/`right` are Tiptap docs).
  - `open`: free-text answer, graded manually by an instructor - no `correct_answer`/`options` needed.

  ## quiz_exam

  ```json
  {
    "count": 10,
    "time_limit": 900,
    "allowed_blur_attempts": 3,
    "mandatory_tags": ["sql"],
    "include_tags": [],
    "exclude_tags": [],
    "slots": [{"id": "s1", "count": 2, "tags": ["easy"]}]
  }
  ```

  Required: `count` (1-100), `allowed_blur_attempts`. Dynamically assembles
  a test from pinned library blocks matching tags at the moment a student
  takes it - it does NOT store questions on the block itself.
  **Read `athena://docs/library-and-exams` before using this type**: the
  question pool is restricted to library blocks pinned to THIS course
  specifically (via `pin_library_block`), and the tag-matching rules for
  `mandatory_tags`/`include_tags`/`exclude_tags` vs. `slots` are not what
  you'd guess (overlap vs. subset matching, respectively).

  ## ticket_exam

  ```json
  {"time_limit": 1800, "allowed_blur_attempts": 3, "slots": [{"id": "s1", "tags": ["sql"]}]}
  ```

  Same idea as `quiz_exam` but always slot-based, one block per slot, with
  usage-balancing across repeat attempts. See `athena://docs/library-and-exams`.

  ## code

  ```json
  {
    "language": "python3",
    "time_limit": 1.0,
    "memory_limit": 65536,
    "max_attempts": null,
    "initial_code": "def solve():\\n    pass",
    "solution_code": "def solve():\\n    return 42",
    "body": {"type": "doc", "content": [{"type": "paragraph", "content": [{"type": "text", "text": "Return the answer to everything."}]}]},
    "test_cases": [{"input": "", "expected_output": "42", "is_hidden": false, "weight": 10}]
  }
  ```

  `language` is one of exactly three runnable values - anything else
  silently never executes (it isn't rejected at save time, it just always
  fails to run):

  | `language` | runtime | notes |
  |---|---|---|
  | `"python3"` | isolate sandbox | the default if `language` is omitted |
  | `"cpp"` | isolate sandbox (compiled with `g++ -O3` first) | compilation itself always gets a fixed 10s/256MB budget, independent of this block's own `time_limit`/`memory_limit` |
  | `"sql"` | ephemeral Postgres sandbox | completely different `content.body` shape - see below |

  Do NOT use `"python"` (no trailing `3`) - it looks plausible and the
  changeset accepts it as a string, but no runner exists for it, so the
  block can never actually be graded. Values like `"java"`/`"go"`/
  `"rust"`/`"javascript"` exist only as CodeMirror *editor syntax
  highlighting* modes elsewhere in the app - they are not executable
  languages here regardless of what you put in `content`.

  - `time_limit`: seconds, `0 < time_limit <= 15`, applies identically to
    `python3` and `cpp` (there's no per-language default). `memory_limit`:
    KB, `256 <= memory_limit <= 524288`, same story.
  - `test_cases` (python3/cpp only): stdin (`input`) / expected stdout
    (`expected_output`) pairs; `weight` is the points awarded, `is_hidden: true`
    hides it from students (still graded, just not shown in feedback).

  ### `language: "sql"` - SQL challenge

  **This is the shape that trips people up**: the SQL-specific settings
  (`evaluation_mode`, `setup_sql`, `solution_sql`, `check_sql`) are NOT their
  own top-level `content` keys - they live *inside* `content.body`,
  alongside the Tiptap task description. When updating `body` later, merge
  into the existing map rather than replacing it wholesale, or you'll wipe
  out either the description or the SQL settings.

  ```json
  {
    "language": "sql",
    "time_limit": 5.0,
    "memory_limit": 65536,
    "initial_code": "-- write your query here\\n",
    "solution_code": "",
    "body": {
      "type": "doc",
      "content": [{"type": "paragraph", "content": [{"type": "text", "text": "Return the name of every active user."}]}],
      "evaluation_mode": "query_result",
      "setup_sql": "CREATE TABLE users (id serial primary key, name text, active boolean);\\nINSERT INTO users VALUES (1,'Ann',true),(2,'Bob',false);",
      "solution_sql": "SELECT id, name FROM users WHERE active;"
    }
  }
  ```

  `content.body.evaluation_mode` is `"query_result"` (default) or `"state_verification"`:

  - **`query_result`**: the student's submitted SQL and `content.body.solution_sql`
    both run against the sandbox seeded by `content.body.setup_sql`; their
    result sets (columns + rows) are compared for equality, order-insensitive.
  - **`state_verification`**: after the student's SQL runs, `content.body.check_sql`
    runs next. It must return exactly one row with one column equal to the
    literal string `"OK"` to pass - any other single value is shown to the
    student as the failure message. Use this when correctness depends on
    resulting table state rather than a query's own output (e.g. an `INSERT`/
    `UPDATE` task).

  `initial_code`/`solution_code` (the top-level fields, not inside `body`)
  are only meaningful for non-SQL languages - for SQL, leave them empty or a
  starter comment, since the student's actual query is submitted and
  evaluated at runtime rather than stored on the block.
  """

  @impl EMCP.Resource
  def uri, do: "athena://docs/block-content-schemas"

  @impl EMCP.Resource
  def name, do: "block_content_schemas"

  @impl EMCP.Resource
  def description,
    do:
      "Exact JSON shape of the `content` field for every block `type`, including the SQL " <>
        "code-challenge evaluation modes. Read this before calling create_block/update_block/" <>
        "create_library_block."

  @impl EMCP.Resource
  def mime_type, do: "text/markdown"

  @impl EMCP.Resource
  def read(_conn), do: @markdown_content
end
