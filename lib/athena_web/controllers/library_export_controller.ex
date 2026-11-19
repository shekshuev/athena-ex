defmodule AthenaWeb.LibraryExportController do
  use AthenaWeb, :controller

  alias Athena.Content

  def download(conn, params) do
    result =
      with {:ok, user} <- export_user(conn.assigns.current_user) do
        params = normalize_params(params)

        Content.export_library_questions(user, params, params["format"],
          base_url: AthenaWeb.Endpoint.url()
        )
      end

    export_response(conn, result)
  end

  defp export_user(%{status: :active, must_change_password: false} = user), do: {:ok, user}
  defp export_user(_user), do: {:error, :forbidden}

  defp normalize_params(params) do
    case params["export"] do
      nil -> params
      %{} = form -> Map.merge(params, Map.take(form, ["scope", "format"]))
      _ -> Map.put(params, "scope", "invalid")
    end
  end

  defp export_response(conn, {:ok, file}) do
    conn
    |> put_resp_content_type(file.content_type)
    |> put_resp_header("cache-control", "no-store")
    |> send_download({:binary, file.body},
      filename: file.filename,
      content_type: file.content_type
    )
  end

  defp export_response(conn, {:error, :forbidden}), do: send_resp(conn, 403, "Forbidden")

  defp export_response(conn, {:error, :no_questions}),
    do: send_resp(conn, 422, gettext("No questions to export."))

  defp export_response(conn, {:error, {:unsupported_question, _id, title}}) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(
      422,
      gettext(
        "Cannot export question: %{title}. Its content is unsupported or incomplete. Try Moodle XML if GIFT cannot represent the answer.",
        title: title
      )
    )
  end

  defp export_response(conn, {:error, _}), do: send_resp(conn, 400, "Invalid export parameters")
end
