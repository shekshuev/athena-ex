defmodule Athena.Learning.Gradebook do
  @moduledoc """
  The teacher's gradebook: one row per student (or one row per team for a
  `:team` cohort), one column per gradable block of a course, a score in
  every cell - the Moodle "grader report" shape.

  Pure scores only: nothing here reads engagement telemetry, so the plain
  gradebook stays a single cheap query no matter how much behavioural data
  a course has collected.

  Which submissions count:

    * only top-level ones (an exam's per-question children roll up into
      their parent's score already, see `Athena.Learning.Evaluator`);
    * never drafts, instructor test runs, or daily-challenge re-attempts
      (same exclusions as the grading list);
    * academic cohorts match by student (`Submission.cohort_id` is only ever
      set for `:team` cohorts - see
      `Athena.Learning.Submissions.list_group_submissions_for_block/2`),
      team cohorts match by the team's own `cohort_id`.

  When a student has several attempts on a block, `filters.attempt` picks
  the one shown: `:best` (highest final score; the default, as in Moodle),
  `:last` or `:first`. `filters.from`/`filters.to` restrict which attempts
  are considered at all, by submission date in the app timezone.
  """

  import Ecto.Query

  alias Athena.{Content, Identity, Repo, TimeZones}
  alias Athena.Announcements
  alias Athena.Content.Block
  alias Athena.Learning.{Cohort, Cohorts, Submission}

  @final_statuses ~w(graded accepted wrong_answer time_limit_exceeded memory_limit_exceeded
                     runtime_error compilation_error rejected)a
  @in_progress_statuses ~w(pending processing system_error)a

  @attempt_policies [:best, :last, :first]
  @status_filters [:all, :failed, :review, :not_started, :in_progress]
  @default_threshold 50

  @type filters :: %{
          optional(:block_ids) => [binary()] | nil,
          optional(:types) => [atom()],
          optional(:account_ids) => [binary()] | nil,
          optional(:from) => Date.t() | nil,
          optional(:to) => Date.t() | nil,
          optional(:attempt) => :best | :last | :first
        }

  @type cell :: %{
          state: :scored | :review | :in_progress,
          score: integer() | nil,
          status: atom(),
          attempts: pos_integer(),
          submission_id: binary(),
          submitted_at: DateTime.t(),
          integrity: :confirmed | :red | :yellow | nil
        }

  @doc "Attempt policies `build/3` accepts, default first."
  @spec attempt_policies() :: [atom()]
  def attempt_policies, do: @attempt_policies

  @doc "Cell status filters `matches_status?/3` understands, default first."
  @spec status_filters() :: [atom()]
  def status_filters, do: @status_filters

  @doc "Pass mark (out of 100) used when a caller doesn't choose one."
  @spec default_threshold() :: pos_integer()
  def default_threshold, do: @default_threshold

  @doc """
  Builds the gradebook for `cohort` on `course_id`.

  Returns:

    * `:catalog` - every gradable block of the course, grouped by section in
      course order (`[%{section, blocks: [column]}]`), for block pickers;
    * `:columns` - the columns left after the `:block_ids`/`:types` filters;
    * `:all_rows` / `:rows` - every row (students or the team) and the ones
      left after the `:account_ids` filter, sorted by name;
    * `:cells` - `%{{row_id, block_id} => cell}`; a missing key means the
      student never submitted anything for that block (in the date range).
  """
  @spec build(Cohort.t(), binary(), filters()) :: map()
  def build(%Cohort{} = cohort, course_id, filters \\ %{}) do
    catalog = catalog(course_id)
    columns = select_columns(catalog, filters)
    all_rows = rows_for(cohort)
    rows = select_rows(all_rows, Map.get(filters, :account_ids))
    policy = Map.get(filters, :attempt, :best)

    cells =
      cohort
      |> submissions_query(Enum.map(columns, & &1.block.id), Enum.map(rows, & &1.id), filters)
      |> Repo.all()
      |> Enum.group_by(&{row_key(cohort, &1), &1.block_id})
      |> Map.new(fn {key, attempts} -> {key, to_cell(attempts, policy)} end)

    %{catalog: catalog, columns: columns, all_rows: all_rows, rows: rows, cells: cells}
  end

  @doc """
  Whether a cell (or `nil` - not started) matches a status filter, given
  the pass mark: `:failed` is a final score below `threshold`.
  """
  @spec matches_status?(cell() | nil, atom(), integer()) :: boolean()
  def matches_status?(_cell, :all, _threshold), do: true
  def matches_status?(nil, :not_started, _threshold), do: true
  def matches_status?(%{state: :review}, :review, _threshold), do: true
  def matches_status?(%{state: :in_progress}, :in_progress, _threshold), do: true

  def matches_status?(%{state: :scored, score: score}, :failed, threshold),
    do: score < threshold

  def matches_status?(_cell, _status, _threshold), do: false

  @doc """
  Per-row summary over `block_ids`: average of final scores (`nil` when
  there are none), how many blocks are passed (score >= `threshold`) and
  how many blocks there are.
  """
  @spec row_summary(map(), binary(), [binary()], integer()) :: map()
  def row_summary(%{cells: cells}, row_id, block_ids, threshold) do
    block_ids
    |> Enum.map(&Map.get(cells, {row_id, &1}))
    |> summarize(threshold, length(block_ids))
  end

  @doc """
  Per-column summary over `row_ids`: average final score, how many rows
  passed, how many submitted anything, and how many rows there are.
  """
  @spec column_summary(map(), binary(), [binary()], integer()) :: map()
  def column_summary(%{cells: cells}, block_id, row_ids, threshold) do
    row_ids
    |> Enum.map(&Map.get(cells, {&1, block_id}))
    |> summarize(threshold, length(row_ids))
  end

  defp summarize(cells, threshold, total) do
    scores = for %{state: :scored, score: score} <- cells, do: score

    %{
      average: if(scores == [], do: nil, else: Enum.sum(scores) / length(scores)),
      passed: Enum.count(scores, &(&1 >= threshold)),
      submitted: Enum.count(cells, &(&1 != nil)),
      total: total
    }
  end

  # Course structure

  defp catalog(course_id) do
    sections = course_id |> Content.get_course_tree(:all) |> flatten_sections()

    blocks_by_section =
      sections
      |> Enum.map(& &1.id)
      |> Content.list_blocks_by_section_ids()
      |> Enum.filter(&Block.gradable?/1)
      |> Enum.group_by(& &1.section_id)

    sections
    |> Enum.map(fn section ->
      columns =
        blocks_by_section
        |> Map.get(section.id, [])
        |> Enum.sort_by(& &1.order)
        |> Enum.with_index(1)
        |> Enum.map(fn {block, number} -> column(block, section, number) end)

      %{section: section, blocks: columns}
    end)
    |> Enum.reject(&(&1.blocks == []))
  end

  defp flatten_sections(sections) do
    Enum.flat_map(sections, fn section -> [section | flatten_sections(section.children)] end)
  end

  defp column(block, section, number) do
    %{
      block: block,
      section: section,
      number: number,
      preview: block_preview(block)
    }
  end

  defp block_preview(%Block{content: %{"body" => body}}) when is_map(body) do
    body |> Announcements.preview_text() |> String.slice(0, 120)
  end

  defp block_preview(_block), do: ""

  defp select_columns(catalog, filters) do
    block_ids = Map.get(filters, :block_ids)
    types = Map.get(filters, :types, [])

    for %{blocks: columns} <- catalog,
        column <- columns,
        is_nil(block_ids) or column.block.id in block_ids,
        types == [] or column.block.type in types,
        do: column
  end

  # Rows

  defp rows_for(%Cohort{type: :team} = cohort) do
    [%{id: cohort.id, name: cohort.name, login: nil}]
  end

  defp rows_for(%Cohort{id: cohort_id}) do
    case Cohorts.list_cohort_memberships(cohort_id, %{limit: 1000}) do
      {:ok, {memberships, _meta}} ->
        memberships
        |> Enum.reject(&is_nil(&1.account))
        |> Enum.map(fn %{account: account} ->
          %{id: account.id, name: student_name(account), login: account.login}
        end)
        |> Enum.sort_by(&String.downcase(&1.name))

      _ ->
        []
    end
  end

  defp student_name(account) do
    case Identity.display_name(account) do
      name when name in [nil, ""] -> account.login
      name -> name
    end
  end

  defp select_rows(all_rows, nil), do: all_rows
  defp select_rows(all_rows, account_ids), do: Enum.filter(all_rows, &(&1.id in account_ids))

  defp row_key(%Cohort{type: :team, id: cohort_id}, _submission), do: cohort_id
  defp row_key(_cohort, submission), do: submission.account_id

  # Submissions

  defp submissions_query(cohort, block_ids, row_ids, filters) do
    from(s in Submission,
      where:
        s.block_id in ^block_ids and s.status != :draft and is_nil(s.parent_submission_id) and
          s.origin != :daily_challenge and fragment("?->>'is_test_run' IS NULL", s.content),
      order_by: [asc: s.inserted_at, asc: s.id],
      select: %{
        id: s.id,
        account_id: s.account_id,
        block_id: s.block_id,
        status: s.status,
        score: s.score,
        inserted_at: s.inserted_at,
        risk_level: fragment("?->>'risk_level'", s.content),
        review_status: fragment("?->'proctoring_review'->>'status'", s.content)
      }
    )
    |> scope_to_rows(cohort, row_ids)
    |> maybe_from(Map.get(filters, :from))
    |> maybe_to(Map.get(filters, :to))
  end

  defp scope_to_rows(query, %Cohort{type: :team, id: cohort_id}, _row_ids),
    do: where(query, [s], s.cohort_id == ^cohort_id)

  defp scope_to_rows(query, _cohort, row_ids),
    do: where(query, [s], s.account_id in ^row_ids and is_nil(s.cohort_id))

  defp maybe_from(query, nil), do: query

  defp maybe_from(query, %Date{} = from) do
    since = TimeZones.start_of_day(from)
    where(query, [s], s.inserted_at >= ^since)
  end

  defp maybe_to(query, nil), do: query

  defp maybe_to(query, %Date{} = to) do
    until = to |> Date.add(1) |> TimeZones.start_of_day()
    where(query, [s], s.inserted_at < ^until)
  end

  # `attempts` arrive oldest first (see the query's `order_by`).
  defp to_cell(attempts, policy) do
    chosen = choose_attempt(attempts, policy)
    state = state_of(chosen.status)

    %{
      state: state,
      score: if(state == :scored, do: chosen.score, else: nil),
      status: chosen.status,
      attempts: length(attempts),
      submission_id: chosen.id,
      submitted_at: chosen.inserted_at,
      integrity: integrity(chosen)
    }
  end

  # The cheating monitor's verdict on the shown attempt: a teacher's own
  # review always wins over the automatic risk level.
  defp integrity(%{review_status: "confirmed"}), do: :confirmed
  defp integrity(%{review_status: "dismissed"}), do: nil
  defp integrity(%{risk_level: "red"}), do: :red
  defp integrity(%{risk_level: "yellow"}), do: :yellow
  defp integrity(_attempt), do: nil

  defp choose_attempt(attempts, :first), do: List.first(attempts)
  defp choose_attempt(attempts, :last), do: List.last(attempts)

  # Highest final score; ties go to the earliest such attempt. With no final
  # attempt yet, fall back to the latest one so a cell still says "under
  # review"/"in progress" rather than looking untouched.
  defp choose_attempt(attempts, :best) do
    case Enum.filter(attempts, &(&1.status in @final_statuses)) do
      [] -> List.last(attempts)
      final -> Enum.max_by(final, & &1.score, fn -> nil end)
    end
  end

  defp state_of(status) when status in @final_statuses, do: :scored
  defp state_of(:needs_review), do: :review
  defp state_of(status) when status in @in_progress_statuses, do: :in_progress
end
