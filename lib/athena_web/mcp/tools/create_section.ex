defmodule AthenaWeb.MCP.Tools.CreateSection do
  @moduledoc "MCP tool: create_section."
  @behaviour EMCP.Tool

  alias Athena.Content
  alias AthenaWeb.MCP.Tools.{Errors, RuleAttrs, Serializers}

  @impl EMCP.Tool
  def name, do: "create_section"

  @impl EMCP.Tool
  def description,
    do:
      "Creates a section (module/chapter/lesson) in a course, optionally nested under a " <>
        "parent. See athena://docs/progression-rules before setting access_rules/engagement_rule."

  @impl EMCP.Tool
  def input_schema do
    %{
      type: :object,
      properties: %{
        course_id: %{type: :string},
        title: %{type: :string},
        parent_id: %{type: :string},
        visibility: %{
          type: :string,
          description: "\"enrolled\" (default), \"restricted\", or \"hidden\"."
        },
        access_rules: %{
          type: :object,
          description:
            "Time-lock / waterline settings - only takes effect when visibility is " <>
              "\"restricted\". See athena://docs/progression-rules."
        },
        engagement_rule: %{
          type: :object,
          description: "Engagement-nudge thresholds. See athena://docs/progression-rules."
        }
      },
      required: [:course_id, :title]
    }
  end

  @impl EMCP.Tool
  def call(conn, args) do
    user = conn.assigns.current_user

    attrs =
      Map.take(args, [
        "course_id",
        "title",
        "parent_id",
        "visibility",
        "access_rules",
        "engagement_rule"
      ])
      |> RuleAttrs.normalize()

    case Content.create_section(user, attrs) do
      {:ok, section} -> Errors.ok(Serializers.section(section))
      error -> Errors.error(error)
    end
  end
end
