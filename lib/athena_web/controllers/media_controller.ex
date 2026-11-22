defmodule AthenaWeb.MediaController do
  @moduledoc "Authorizes media downloads before redirecting to a short-lived signed URL."
  use AthenaWeb, :controller

  alias Athena.{Identity, Media}

  def download(conn, %{"path" => path_list}) do
    with account_id when is_binary(account_id) <- get_session(conn, "account_id"),
         {:ok, %{status: :active} = user} <- Identity.get_account(account_id, preload: [:role]),
         {:ok, url} <- Media.download_url(user, Enum.join(path_list, "/")) do
      redirect(conn, external: url)
    else
      _ -> conn |> put_status(:forbidden) |> text("Forbidden")
    end
  end
end
