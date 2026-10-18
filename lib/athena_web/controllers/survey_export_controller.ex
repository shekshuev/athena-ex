defmodule AthenaWeb.SurveyExportController do
  @moduledoc """
  Downloads a survey's answers as CSV, in either of two shapes.

  `export.csv` is wide - one row per respondent, one column per question -
  which is what a spreadsheet wants. `export.long.csv` is tidy - one row per
  answer - which is what SPSS and R want, since every analysis in those tools
  starts by reshaping a wide table into exactly this.

  A plain controller rather than a LiveView: a download is a request for a
  file, and routing it through a socket would mean holding the whole table in
  memory on the server to push it back out again.

  Formatting conventions follow `AthenaWeb.GradebookExportController`: a UTF-8
  BOM so Excel reads Cyrillic correctly, and `;` as the separator in the
  Russian locale, where Excel expects it.

  The respondent column comes from the same labelling function the results
  screen uses, so a cohort respondent is a cohort and an opaque number here
  too, and no account id is written. Timestamps are days, not instants - see
  `Athena.Surveys.Export`.
  """
  use AthenaWeb, :controller

  alias Athena.{Identity, Surveys}

  def download(conn, %{"id" => survey_id} = params) do
    export(conn, survey_id, params, :wide)
  end

  def download_long(conn, %{"id" => survey_id} = params) do
    export(conn, survey_id, params, :long)
  end

  defp export(conn, survey_id, params, shape) do
    user = conn.assigns.current_user

    with %{} = survey <- Surveys.get_survey(survey_id),
         true <- Identity.can?(user, "surveys.results.export"),
         # The record-level policy as well as the permission: a role holding
         # the export right under `own_only` must be refused on someone
         # else's survey, not merely kept off the screen that links here.
         true <- Identity.can?(user, "surveys.read", survey) do
      opts = cohort_opts(params)
      table = build(survey.id, shape, opts)

      conn
      |> put_resp_content_type("text/csv")
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="#{filename(survey, shape)}")
      )
      |> send_resp(200, "﻿" <> to_csv(table, separator()))
    else
      nil -> send_resp(conn, 404, "Not found")
      _ -> send_resp(conn, 403, "Forbidden")
    end
  end

  defp build(survey_id, :wide, opts), do: Surveys.export_wide(survey_id, opts)
  defp build(survey_id, :long, opts), do: Surveys.export_long(survey_id, opts)

  defp cohort_opts(%{"cohort_id" => cohort_id}) when is_binary(cohort_id) and cohort_id != "",
    do: [cohort_id: cohort_id]

  defp cohort_opts(_params), do: []

  defp filename(survey, shape) do
    suffix = if shape == :long, do: "_long", else: ""

    "survey_#{slug(survey.title)}#{suffix}.csv"
  end

  defp to_csv(%{headers: headers, rows: rows}, separator) do
    Enum.map_join([headers | rows], "\r\n", &csv_line(&1, separator))
  end

  defp separator do
    if Gettext.get_locale(AthenaWeb.Gettext) == "ru", do: ";", else: ","
  end

  defp csv_line(values, separator),
    do: Enum.map_join(values, separator, &csv_escape(&1, separator))

  defp csv_escape(nil, _separator), do: ""
  defp csv_escape(true, _separator), do: "true"
  defp csv_escape(false, _separator), do: "false"

  defp csv_escape(value, separator) do
    string = to_string(value)

    # A leading =, +, - or @ makes Excel and Sheets evaluate the cell as a
    # formula. Survey answers are arbitrary text typed by students, so this
    # is a live concern rather than a theoretical one, and prefixing with a
    # quoted apostrophe keeps the text intact while disarming it.
    string = if String.starts_with?(string, ["=", "+", "-", "@"]), do: "'" <> string, else: string

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
    |> String.slice(0, 60)
  end
end
