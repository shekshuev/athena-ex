defmodule AthenaWeb.MCP.Tools.CreateBlock do
  @moduledoc "MCP tool: create_block."
  @behaviour EMCP.Tool

  alias Athena.Content
  alias AthenaWeb.MCP.Tools.{Errors, RuleAttrs, Serializers}

  @impl EMCP.Tool
  def name, do: "create_block"

  @impl EMCP.Tool
  def description,
    do:
      "Creates a content block inside a section. IMPORTANT: read " <>
        "athena://docs/block-content-schemas first for the `content` shape (varies by " <>
        "`type` - e.g. an SQL code challenge's evaluation settings live nested inside " <>
        "content.body), and athena://docs/progression-rules before setting access_rules/" <>
        "completion_rule/engagement_rule."

  @impl EMCP.Tool
  def input_schema do
    %{
      type: :object,
      properties: %{
        section_id: %{type: :string},
        type: %{
          type: :string,
          description:
            "One of: text, code, quiz_question, quiz_exam, ticket_exam, video, image, " <>
              "attachment, file_assignment. See athena://docs/block-content-schemas."
        },
        content: %{
          type: :object,
          description:
            "Shape depends on `type` - see the athena://docs/block-content-schemas resource " <>
              "for the exact fields (and the SQL code-challenge evaluation modes)."
        },
        order: %{type: :integer},
        after_id: %{type: :string},
        visibility: %{
          type: :string,
          description: "\"enrolled\" (default), \"restricted\", \"hidden\", or \"inherit\"."
        },
        access_rules: %{
          type: :object,
          description:
            "Time-lock / waterline settings - only takes effect when visibility is " <>
              "\"restricted\". See athena://docs/progression-rules."
        },
        completion_rule: %{
          type: :object,
          description:
            "How the student unlocks the next block (none/button/submit/pass_auto_grade). " <>
              "See athena://docs/progression-rules."
        },
        engagement_rule: %{
          type: :object,
          description: "Engagement-nudge thresholds. See athena://docs/progression-rules."
        }
      },
      required: [:section_id, :type, :content]
    }
  end

  @impl EMCP.Tool
  def call(conn, args) do
    user = conn.assigns.current_user

    attrs =
      args
      |> Map.take([
        "section_id",
        "type",
        "content",
        "order",
        "after_id",
        "visibility",
        "access_rules",
        "completion_rule",
        "engagement_rule"
      ])
      |> RuleAttrs.normalize()

    case Content.create_block(user, attrs) do
      {:ok, block} -> Errors.ok(Serializers.block(block))
      error -> Errors.error(error)
    end
  end
end
