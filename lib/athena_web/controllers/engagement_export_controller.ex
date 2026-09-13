defmodule AthenaWeb.EngagementExportController do
  @moduledoc """
  Downloads the "wide" engagement metrics table (one row per student ×
  block) as CSV, for a teacher to load into R/Python/SPSS - see
  `Athena.Engagement.Metrics.export_wide_table/2`. A plain controller
  action rather than a LiveView route since a file download needs a real
  HTTP response, not a socket push.
  """
  use AthenaWeb, :controller

  alias Athena.{Engagement, Identity}

  def download(conn, %{"id" => cohort_id, "course_id" => course_id}) do
    if Identity.can?(conn.assigns.current_user, "engagement.read") do
      csv = course_id |> Engagement.export_wide_table([cohort_id]) |> to_csv()

      conn
      |> put_resp_content_type("text/csv")
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="engagement_#{course_id}_#{cohort_id}.csv")
      )
      |> send_resp(200, csv)
    else
      send_resp(conn, 403, "Forbidden")
    end
  end

  defp to_csv([]), do: ""

  defp to_csv(rows) do
    headers = rows |> List.first() |> Map.keys() |> Enum.sort()

    [headers | Enum.map(rows, fn row -> Enum.map(headers, &Map.get(row, &1)) end)]
    |> Enum.map_join("\n", &csv_line/1)
  end

  defp csv_line(values), do: Enum.map_join(values, ",", &csv_escape/1)

  defp csv_escape(nil), do: ""

  defp csv_escape(value) do
    string = to_string(value)

    if String.contains?(string, [",", "\"", "\n"]) do
      "\"" <> String.replace(string, "\"", "\"\"") <> "\""
    else
      string
    end
  end
end
