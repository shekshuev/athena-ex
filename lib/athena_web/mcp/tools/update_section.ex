defmodule AthenaWeb.MCP.Tools.UpdateSection do
  @moduledoc "MCP tool: update_section."
  @behaviour EMCP.Tool

  alias Athena.Content
  alias AthenaWeb.MCP.Tools.{Errors, RuleAttrs, Serializers}

  @impl EMCP.Tool
  def name, do: "update_section"

  @impl EMCP.Tool
  def description,
    do:
      "Updates a section's title, parent, visibility, order, access_rules, or " <>
        "engagement_rule. access_rules/engagement_rule REPLACE the whole embedded object " <>
        "(no field-level merge) - see athena://docs/progression-rules."

  @impl EMCP.Tool
  def input_schema do
    %{
      type: :object,
      properties: %{
        section_id: %{type: :string},
        title: %{type: :string},
        parent_id: %{type: :string},
        visibility: %{
          type: :string,
          description: "\"enrolled\", \"restricted\", or \"hidden\"."
        },
        order: %{type: :integer},
        access_rules: %{
          type: :object,
          description:
            "Full replacement value - only takes effect when visibility is \"restricted\". " <>
              "See athena://docs/progression-rules."
        },
        engagement_rule: %{
          type: :object,
          description: "Full replacement value. See athena://docs/progression-rules."
        }
      },
      required: [:section_id]
    }
  end

  @impl EMCP.Tool
  def call(conn, %{"section_id" => section_id} = args) do
    user = conn.assigns.current_user

    attrs =
      args
      |> Map.take([
        "title",
        "parent_id",
        "visibility",
        "order",
        "access_rules",
        "engagement_rule"
      ])
      |> RuleAttrs.normalize()

    with {:ok, section} <- Content.get_section(user, section_id),
         {:ok, updated} <- Content.update_section(user, section, attrs) do
      Errors.ok(Serializers.section(updated))
    else
      error -> Errors.error(error)
    end
  end
end
