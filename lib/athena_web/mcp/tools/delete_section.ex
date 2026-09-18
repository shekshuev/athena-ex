defmodule AthenaWeb.MCP.Tools.DeleteSection do
  @moduledoc "MCP tool: delete_section."
  @behaviour EMCP.Tool

  alias Athena.Content
  alias AthenaWeb.MCP.Tools.{Errors, Serializers}

  @impl EMCP.Tool
  def name, do: "delete_section"

  @impl EMCP.Tool
  def description,
    do: "Permanently deletes a section and all of its descendant sections/blocks."

  @impl EMCP.Tool
  def annotations, do: %{destructiveHint: true}

  @impl EMCP.Tool
  def input_schema do
    %{
      type: :object,
      properties: %{section_id: %{type: :string}},
      required: [:section_id]
    }
  end

  @impl EMCP.Tool
  def call(conn, %{"section_id" => section_id}) do
    user = conn.assigns.current_user

    with {:ok, section} <- Content.get_section(user, section_id),
         {:ok, deleted} <- Content.delete_section(user, section) do
      Errors.ok(Serializers.section(deleted))
    else
      error -> Errors.error(error)
    end
  end
end
