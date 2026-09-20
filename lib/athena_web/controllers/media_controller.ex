defmodule AthenaWeb.MediaController do
  @moduledoc """
  Serves as a secure proxy for downloading private media files from S3/MinIO.

  Because media files are stored in private buckets, direct access via public URLs
  is denied. This controller acts as a gatekeeper: it verifies the user's session
  and, if authenticated, generates a temporary presigned URL, issuing an HTTP 302
  redirect to the actual file.
  """
  use AthenaWeb, :controller

  alias Athena.Media

  @doc """
  Intercepts requests to private media, verifies authentication,
  generates a temporary presigned URL, and redirects the client to the S3 object.

  Returns `403 Forbidden` if the user is not authenticated in the session,
  or if the key belongs to a `:personal` file the caller isn't the owner
  of, doesn't have shared with them, and isn't public (see
  `Media.can_download_personal_file?/2`). Every other media context
  (avatars, course materials, submissions) keeps its previous behavior:
  reachable by any authenticated account, since their access is already
  governed elsewhere (enrollment gates what a student ever sees a course
  material's URL at all, etc.) - personal files have no such prior gate,
  which is exactly what made them downloadable by key alone before.
  Returns `404 Not Found` if the presigned URL generation fails.
  """
  @spec download(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def download(conn, %{"path" => path_list}) do
    case get_session(conn, "account_id") do
      nil ->
        forbidden(conn)

      account_id ->
        key = Enum.join(path_list, "/")

        if authorized?(account_id, key) do
          serve(conn, key)
        else
          forbidden(conn)
        end
    end
  end

  defp authorized?(account_id, key) do
    case Media.get_file_by_key(key) do
      %{context: :personal} = file -> Media.can_download_personal_file?(account_id, file)
      _ -> true
    end
  end

  defp serve(conn, key) do
    bucket = Application.get_env(:athena, Athena.Media)[:bucket] || "athena"

    case Media.generate_download_url(bucket, key) do
      {:ok, presigned_url} ->
        redirect(conn, external: presigned_url)

      {:error, _reason} ->
        conn
        |> put_status(:not_found)
        |> text("Media not found")
    end
  end

  defp forbidden(conn) do
    conn
    |> put_status(:forbidden)
    |> text("Forbidden")
  end
end
