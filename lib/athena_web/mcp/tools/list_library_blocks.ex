defmodule AthenaWeb.MCP.Tools.ListLibraryBlocks do
  @moduledoc "MCP tool: list_library_blocks."
  @behaviour EMCP.Tool

  alias Athena.Content
  alias AthenaWeb.MCP.Tools.{Errors, Serializers}

  @impl EMCP.Tool
  def name, do: "list_library_blocks"

  @impl EMCP.Tool
  def description,
    do:
      "Lists reusable library blocks visible to the authenticated account. Pass course_id + " <>
        "pinned_only=true to see exactly what's pinned to a course (i.e. eligible for that " <>
        "course's quiz_exam/ticket_exam pools) - see athena://docs/library-and-exams."

  @impl EMCP.Tool
  def input_schema do
    %{
      type: :object,
      properties: %{
        course_id: %{type: :string},
        pinned_only: %{
          type: :boolean,
          description: "Only list blocks pinned to course_id. Requires course_id."
        },
        tag_search: %{type: :string, description: "Comma-separated substring match against tags."},
        page: %{type: :integer},
        page_size: %{type: :integer}
      }
    }
  end

  @impl EMCP.Tool
  def call(conn, args) do
    user = conn.assigns.current_user
    params = Map.take(args, ["course_id", "pinned_only", "tag_search", "page", "page_size"])

    case Content.list_library_blocks(user, params) do
      {:ok, {library_blocks, meta}} ->
        Errors.ok(%{
          library_blocks: Enum.map(library_blocks, &Serializers.library_block/1),
          total_count: meta.total_count
        })

      error ->
        Errors.error(error)
    end
  end
end
