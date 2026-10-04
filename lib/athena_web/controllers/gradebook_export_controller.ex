defmodule AthenaWeb.GradebookExportController do
  @moduledoc """
  Downloads the gradebook as CSV - exactly the rows and tasks the teacher
  currently has on screen (same URL filters, same
  `AthenaWeb.TeachingLive.GradebookTable.prepare/2`), with collapsed
  sections expanded back into one column per task.

  Written for spreadsheets rather than statistics packages: a UTF-8 BOM so
  Excel reads Cyrillic names correctly, and `;` as the separator in the
  Russian locale, where Excel expects it.
  """
  use AthenaWeb, :controller

  alias Athena.{Content, Identity, Learning}
  alias AthenaWeb.TeachingLive.{GradebookParams, GradebookTable}

  def download(conn, %{"id" => cohort_id, "course_id" => course_id} = params) do
    user = conn.assigns.current_user

    with true <- Identity.can?(user, "grading.read"),
         {:ok, cohort} <- Learning.get_cohort(user, cohort_id),
         {:ok, course} <- Content.get_course(course_id) do
      filters = GradebookParams.parse(params)

      gradebook =
        Learning.build_gradebook(cohort, course.id, %{
          block_ids: filters.block_ids,
          types: filters.types,
          account_ids: filters.account_ids,
          from: filters.from,
          to: filters.to,
          attempt: filters.attempt
        })

      table = GradebookTable.prepare(gradebook, filters)

      conn
      |> put_resp_content_type("text/csv")
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="gradebook_#{slug(cohort.name)}.csv")
      )
      |> send_resp(200, "﻿" <> to_csv(gradebook, table, separator()))
    else
      _ -> send_resp(conn, 403, "Forbidden")
    end
  end

  defp to_csv(gradebook, table, separator) do
    columns = Enum.flat_map(table.groups, & &1.columns)

    header =
      [gettext("Student"), gettext("Login")] ++
        Enum.map(columns, &GradebookTable.column_title/1) ++
        [gettext("Average"), gettext("Passed")]

    rows =
      Enum.map(table.rows, fn %{row: row, summary: summary} ->
        [row.name, row.login] ++
          Enum.map(columns, &cell_value(Map.get(gradebook.cells, {row.id, &1.block.id}))) ++
          [summary.average && round(summary.average), "#{summary.passed}/#{summary.total}"]
      end)

    Enum.map_join([header | rows], "\r\n", &csv_line(&1, separator))
  end

  defp cell_value(nil), do: nil
  defp cell_value(%{state: :scored, score: score}), do: score
  defp cell_value(%{state: :review}), do: gettext("Awaiting review")
  defp cell_value(%{state: :in_progress}), do: gettext("Being checked")

  defp separator do
    if Gettext.get_locale(AthenaWeb.Gettext) == "ru", do: ";", else: ","
  end

  defp csv_line(values, separator),
    do: Enum.map_join(values, separator, &csv_escape(&1, separator))

  defp csv_escape(nil, _separator), do: ""

  defp csv_escape(value, separator) do
    string = to_string(value)

    if String.contains?(string, [separator, "\"", "\n", "\r"]) do
      "\"" <> String.replace(string, "\"", "\"\"") <> "\""
    else
      string
    end
  end

  defp slug(name) do
    name
    |> String.replace(~r/[^\p{L}\p{N}]+/u, "_")
    |> String.trim("_")
  end
end
