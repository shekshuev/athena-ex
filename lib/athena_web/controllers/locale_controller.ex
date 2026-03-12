defmodule AthenaWeb.LocaleController do
  use AthenaWeb, :controller

  def set(conn, %{"locale" => locale}) when locale in ["ru", "en"] do
    conn
    |> put_session(:locale, locale)
    |> redirect(to: return_path(conn))
  end

  defp return_path(conn) do
    case get_req_header(conn, "referer") do
      [referer | _] -> URI.parse(referer).path || "/"
      _ -> "/"
    end
  end
end
