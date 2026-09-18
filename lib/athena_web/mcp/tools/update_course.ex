defmodule AthenaWeb.MCP.Tools.UpdateCourse do
  @moduledoc "MCP tool: update_course."
  @behaviour EMCP.Tool

  alias Athena.Content
  alias AthenaWeb.MCP.Tools.{Errors, Serializers}

  @impl EMCP.Tool
  def name, do: "update_course"

  @impl EMCP.Tool
  def description, do: "Updates an existing course's title, description, status, type, or code."

  @impl EMCP.Tool
  def input_schema do
    %{
      type: :object,
      properties: %{
        course_id: %{type: :string},
        title: %{type: :string},
        description: %{type: :string},
        status: %{type: :string},
        type: %{type: :string},
        is_public: %{type: :boolean},
        code: %{type: :string}
      },
      required: [:course_id]
    }
  end

  @impl EMCP.Tool
  def call(conn, %{"course_id" => course_id} = args) do
    user = conn.assigns.current_user
    attrs = Map.take(args, ["title", "description", "status", "type", "is_public", "code"])

    with {:ok, course} <- Content.get_course(user, course_id),
         {:ok, updated} <- Content.update_course(user, course, attrs) do
      Errors.ok(Serializers.course(updated))
    else
      error -> Errors.error(error)
    end
  end
end
