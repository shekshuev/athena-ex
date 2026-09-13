defmodule AthenaWeb.PageController do
  use AthenaWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end

  def redirect_to_messenger(conn, _params) do
    redirect(conn, to: "/messenger")
  end
end
