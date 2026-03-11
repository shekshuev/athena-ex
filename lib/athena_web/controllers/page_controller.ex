defmodule AthenaWeb.PageController do
  use AthenaWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
