defmodule AthenaWeb.MCP.Tools.Errors do
  @moduledoc """
  Shared helpers for mapping `Athena.Content`/`Athena.Identity` results into
  MCP tool responses. Every tool must go through these instead of raising —
  an MCP client expects tool-level failures (forbidden, not found, invalid
  attrs) as an ordinary `isError: true` result, not a transport error.
  """

  @doc "Wraps a plain, JSON-encodable map as a successful tool response."
  def ok(data), do: EMCP.Tool.response([%{"type" => "text", "text" => Jason.encode!(data)}])

  @doc "Maps a `{:error, reason}` tuple from a Content/Identity call to an MCP error result."
  def error({:error, :forbidden}), do: EMCP.Tool.error("Permission denied")
  def error({:error, :not_found}), do: EMCP.Tool.error("Not found")

  def error({:error, %Ecto.Changeset{} = changeset}),
    do: EMCP.Tool.error(changeset_errors(changeset))

  def error({:error, other}), do: EMCP.Tool.error(inspect(other))

  defp changeset_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join("; ", fn {field, errors} -> "#{field}: #{Enum.join(errors, ", ")}" end)
  end
end
