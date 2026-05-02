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

  Returns `403 Forbidden` if the user is not authenticated in the session.
  Returns `404 Not Found` if the presigned URL generation fails.
  """
  @spec download(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def download(conn, %{"path" => path_list}) do
    if get_session(conn, "account_id") do
      key = Enum.join(path_list, "/")
      bucket = Application.get_env(:athena, Media)[:bucket] || "athena"

      case Media.generate_download_url(bucket, key) do
        {:ok, presigned_url} ->
          redirect(conn, external: presigned_url)

        {:error, _reason} ->
          conn
          |> put_status(:not_found)
          |> text("Media not found")
      end
    else
      conn
      |> put_status(:forbidden)
      |> text("Forbidden")
    end
  end
end
