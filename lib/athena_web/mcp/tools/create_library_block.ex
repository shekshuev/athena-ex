defmodule AthenaWeb.MCP.Tools.CreateLibraryBlock do
  @moduledoc "MCP tool: create_library_block."
  @behaviour EMCP.Tool

  alias Athena.Content
  alias AthenaWeb.MCP.Tools.{Errors, Serializers}

  @impl EMCP.Tool
  def name, do: "create_library_block"

  @impl EMCP.Tool
  def description,
    do:
      "Creates a reusable library block, owned by the authenticated account. `content`'s " <>
        "shape depends on `type` - see athena://docs/block-content-schemas (same shapes as " <>
        "create_block). On its own this block belongs to no course - call pin_library_block " <>
        "to attach it to a specific course (required before a quiz_exam/ticket_exam in that " <>
        "course can draw from it); see athena://docs/library-and-exams. Use " <>
        "list_library_blocks first to check for an existing block before creating a duplicate."

  @impl EMCP.Tool
  def input_schema do
    %{
      type: :object,
      properties: %{
        title: %{type: :string},
        type: %{
          type: :string,
          description:
            "One of: text, code, quiz_question, quiz_exam, ticket_exam, video, image, " <>
              "attachment, file_assignment. See athena://docs/block-content-schemas."
        },
        content: %{
          type: :object,
          description: "Shape depends on `type` - see athena://docs/block-content-schemas."
        },
        tags: %{type: :array, items: %{type: :string}},
        is_public: %{type: :boolean}
      },
      required: [:title, :type, :content]
    }
  end

  @impl EMCP.Tool
  def call(conn, args) do
    user = conn.assigns.current_user
    attrs = Map.take(args, ["title", "type", "content", "tags", "is_public"])

    case Content.create_library_block(user, attrs) do
      {:ok, library_block} -> Errors.ok(Serializers.library_block(library_block))
      error -> Errors.error(error)
    end
  end
end
