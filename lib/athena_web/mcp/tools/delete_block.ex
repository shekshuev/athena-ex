defmodule AthenaWeb.MCP.Tools.DeleteBlock do
  @moduledoc "MCP tool: delete_block."
  @behaviour EMCP.Tool

  alias Athena.Content
  alias AthenaWeb.MCP.Tools.{Errors, Serializers}

  @impl EMCP.Tool
  def name, do: "delete_block"

  @impl EMCP.Tool
  def description, do: "Permanently deletes a block."

  @impl EMCP.Tool
  def annotations, do: %{destructiveHint: true}

  @impl EMCP.Tool
  def input_schema do
    %{
      type: :object,
      properties: %{block_id: %{type: :string}},
      required: [:block_id]
    }
  end

  @impl EMCP.Tool
  def call(conn, %{"block_id" => block_id}) do
    user = conn.assigns.current_user

    with {:ok, block} <- Content.get_block(user, block_id),
         {:ok, deleted} <- Content.delete_block(user, block) do
      Errors.ok(Serializers.block(deleted))
    else
      error -> Errors.error(error)
    end
  end
end
