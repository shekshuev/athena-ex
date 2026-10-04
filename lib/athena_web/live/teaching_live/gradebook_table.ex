defmodule AthenaWeb.TeachingLive.GradebookTable do
  @moduledoc """
  Turns an `Athena.Learning.Gradebook` plus the URL filters
  (`AthenaWeb.TeachingLive.GradebookParams`) into exactly what the table
  renders: which column groups are visible or collapsed, which rows survive
  the status filter and in what order, and the per-row/per-column totals.

  Pure functions only, shared by the LiveView and the CSV export, so both
  always agree on what "the current view" is.
  """
  use Gettext, backend: AthenaWeb.Gettext

  alias Athena.Learning.Gradebook

  @doc """
  Returns:

    * `:groups` - `[%{section, collapsed?, columns}]`, one per section with
      at least one visible column, in course order;
    * `:block_ids` - every visible block id (collapsed sections included,
      since their columns still count toward totals);
    * `:rows` - `[%{row, summary}]` after the status filter, sorted;
    * `:column_summaries` - `%{block_id => summary}` over the shown rows.
  """
  @spec prepare(map(), map()) :: map()
  def prepare(gradebook, filters) do
    threshold = filters.threshold
    columns = visible_columns(gradebook, filters)
    block_ids = Enum.map(columns, & &1.block.id)

    rows =
      gradebook.rows
      |> Enum.filter(&row_matches?(gradebook, &1, block_ids, filters))
      |> Enum.map(
        &%{row: &1, summary: Gradebook.row_summary(gradebook, &1.id, block_ids, threshold)}
      )
      |> sort_rows(gradebook, filters)

    row_ids = Enum.map(rows, & &1.row.id)

    %{
      groups: group_columns(columns, filters.collapsed),
      block_ids: block_ids,
      rows: rows,
      column_summaries:
        Map.new(block_ids, &{&1, Gradebook.column_summary(gradebook, &1, row_ids, threshold)})
    }
  end

  # With `compact` on and a status filter set, columns where no student
  # matches the filter are dropped, so "who failed what" fits on a screen.
  defp visible_columns(gradebook, %{compact: true, status: status} = filters)
       when status != :all do
    Enum.filter(gradebook.columns, fn column ->
      Enum.any?(gradebook.rows, fn row ->
        gradebook.cells
        |> Map.get({row.id, column.block.id})
        |> Gradebook.matches_status?(status, filters.threshold)
      end)
    end)
  end

  defp visible_columns(gradebook, _filters), do: gradebook.columns

  defp row_matches?(_gradebook, _row, _block_ids, %{status: :all}), do: true

  defp row_matches?(gradebook, row, block_ids, filters) do
    Enum.any?(block_ids, fn block_id ->
      gradebook.cells
      |> Map.get({row.id, block_id})
      |> Gradebook.matches_status?(filters.status, filters.threshold)
    end)
  end

  defp group_columns(columns, collapsed) do
    columns
    |> Enum.chunk_by(& &1.section.id)
    |> Enum.map(fn [first | _] = group ->
      %{section: first.section, collapsed?: first.section.id in collapsed, columns: group}
    end)
  end

  # Rows with no value for the sort key (no scores yet) always go last,
  # whichever the direction - an empty row is never "the best" or "the worst".
  defp sort_rows(rows, gradebook, %{sort: sort, dir: dir}) do
    {with_value, without_value} =
      rows
      |> Enum.map(&{sort_value(&1, gradebook, sort), &1})
      |> Enum.split_with(fn {value, _row} -> value != nil end)

    sorted = Enum.sort_by(with_value, &elem(&1, 0), dir)
    Enum.map(sorted ++ without_value, &elem(&1, 1))
  end

  defp sort_value(%{row: row}, _gradebook, "name"), do: String.downcase(row.name)
  defp sort_value(%{summary: summary}, _gradebook, "average"), do: summary.average
  defp sort_value(%{summary: summary}, _gradebook, "passed"), do: summary.passed

  defp sort_value(%{row: row}, gradebook, "block:" <> block_id) do
    case Map.get(gradebook.cells, {row.id, block_id}) do
      %{state: :scored, score: score} -> score
      _ -> nil
    end
  end

  @doc "Human label for a gradable block type."
  @spec type_label(atom()) :: String.t()
  def type_label(:code), do: gettext("Code task")
  def type_label(:quiz_question), do: gettext("Question")
  def type_label(:quiz_exam), do: gettext("Exam")
  def type_label(:ticket_exam), do: gettext("Ticket exam")
  def type_label(:file_assignment), do: gettext("File assignment")
  def type_label(type), do: type |> to_string() |> String.replace("_", " ")

  @doc "Hero icon for a gradable block type."
  @spec type_icon(atom()) :: String.t()
  def type_icon(:code), do: "hero-code-bracket"
  def type_icon(:quiz_question), do: "hero-question-mark-circle"
  def type_icon(:quiz_exam), do: "hero-clipboard-document-check"
  def type_icon(:ticket_exam), do: "hero-ticket"
  def type_icon(:file_assignment), do: "hero-document-arrow-up"
  def type_icon(_type), do: "hero-square-3-stack-3d"

  @doc "One-line name of a column, for tooltips and CSV headers."
  @spec column_title(map()) :: String.t()
  def column_title(column) do
    "#{column.section.title} · #{column.number}. #{type_label(column.block.type)}"
  end

  @doc """
  Score band for colouring: `:fail` below the pass mark, `:excellent` from
  85 up (or the pass mark itself, if that is higher), `:pass` in between.
  """
  @spec band(integer(), integer()) :: :fail | :pass | :excellent
  def band(score, threshold) when score < threshold, do: :fail
  def band(score, threshold) when score >= max(threshold, 85), do: :excellent
  def band(_score, _threshold), do: :pass
end
