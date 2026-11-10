defmodule AthenaWeb.Plugs.RememberPermalink do
  @moduledoc "Preserves a permalink across login and a required password change."

  import Plug.Conn

  def init(opts), do: opts

  def call(%{method: "GET", path_info: ["go", kind, id | suffix]} = conn, _opts)
      when kind in ["blocks", "sections"] and suffix in [[], ["edit"]] do
    user = conn.assigns.current_user

    if is_nil(user) or user.must_change_password do
      permalink = "/go/#{kind}/#{URI.encode(id, &URI.char_unreserved?/1)}"
      permalink = if suffix == ["edit"], do: permalink <> "/edit", else: permalink

      path =
        if conn.query_string == "",
          do: permalink,
          else: permalink <> "?" <> conn.query_string

      put_session(conn, :permalink_return_to, path)
    else
      delete_session(conn, :permalink_return_to)
    end
  end

  def call(conn, _opts), do: conn
end
