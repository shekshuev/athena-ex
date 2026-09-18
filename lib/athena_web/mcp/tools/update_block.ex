defmodule AthenaWeb.MCP.Tools.UpdateBlock do
  @moduledoc "MCP tool: update_block."
  @behaviour EMCP.Tool

  alias Athena.Content
  alias AthenaWeb.MCP.Tools.{Errors, RuleAttrs, Serializers}

  @impl EMCP.Tool
  def name, do: "update_block"

  @impl EMCP.Tool
  def description,
    do:
      "Updates a block's type, content, order, visibility, parent section, access_rules, " <>
        "completion_rule, or engagement_rule. `content`/`access_rules`/`completion_rule`/" <>
        "`engagement_rule` each REPLACE the whole field (no deep-merge) - fetch the block's " <>
        "current values first (e.g. via get_course_tree) and send the full object back with " <>
        "your changes, not a partial patch, or you'll silently wipe unrelated fields (e.g. an " <>
        "SQL challenge's content.body.setup_sql). See athena://docs/block-content-schemas and " <>
        "athena://docs/progression-rules."

  @impl EMCP.Tool
  def input_schema do
    %{
      type: :object,
      properties: %{
        block_id: %{type: :string},
        type: %{type: :string},
        content: %{
          type: :object,
          description:
            "Full replacement value - see athena://docs/block-content-schemas. Do not send a " <>
              "partial patch."
        },
        order: %{type: :integer},
        visibility: %{type: :string},
        section_id: %{type: :string},
        access_rules: %{
          type: :object,
          description:
            "Full replacement value - only takes effect when visibility is \"restricted\". " <>
              "See athena://docs/progression-rules."
        },
        completion_rule: %{
          type: :object,
          description: "Full replacement value. See athena://docs/progression-rules."
        },
        engagement_rule: %{
          type: :object,
          description: "Full replacement value. See athena://docs/progression-rules."
        }
      },
      required: [:block_id]
    }
  end

  @impl EMCP.Tool
  def call(conn, %{"block_id" => block_id} = args) do
    user = conn.assigns.current_user

    attrs =
      args
      |> Map.take([
        "type",
        "content",
        "order",
        "visibility",
        "section_id",
        "access_rules",
        "completion_rule",
        "engagement_rule"
      ])
      |> RuleAttrs.normalize()

    with {:ok, block} <- Content.get_block(user, block_id),
         {:ok, updated} <- Content.update_block(user, block, attrs) do
      Errors.ok(Serializers.block(updated))
    else
      error -> Errors.error(error)
    end
  end
end
