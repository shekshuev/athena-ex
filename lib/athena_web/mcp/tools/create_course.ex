defmodule AthenaWeb.MCP.Tools.CreateCourse do
  @moduledoc "MCP tool: create_course."
  @behaviour EMCP.Tool

  alias Athena.Content
  alias AthenaWeb.MCP.Tools.{Errors, Serializers}

  @impl EMCP.Tool
  def name, do: "create_course"

  @impl EMCP.Tool
  def description, do: "Creates a new draft course owned by the authenticated account."

  @impl EMCP.Tool
  def input_schema do
    %{
      type: :object,
      properties: %{
        title: %{type: :string},
        description: %{type: :string},
        type: %{type: :string},
        code: %{type: :string}
      },
      required: [:title]
    }
  end

  @impl EMCP.Tool
  def call(conn, args) do
    user = conn.assigns.current_user
    attrs = Map.take(args, ["title", "description", "type", "code"])

    case Content.create_course(user, attrs) do
      {:ok, course} -> Errors.ok(Serializers.course(course))
      error -> Errors.error(error)
    end
  end
end
