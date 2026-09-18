defmodule AthenaWeb.MCP.Tools.SoftDeleteCourse do
  @moduledoc "MCP tool: soft_delete_course."
  @behaviour EMCP.Tool

  alias Athena.Content
  alias AthenaWeb.MCP.Tools.{Errors, Serializers}

  @impl EMCP.Tool
  def name, do: "soft_delete_course"

  @impl EMCP.Tool
  def description, do: "Soft-deletes (archives) a course. This does not physically remove it."

  @impl EMCP.Tool
  def annotations, do: %{destructiveHint: true}

  @impl EMCP.Tool
  def input_schema do
    %{
      type: :object,
      properties: %{course_id: %{type: :string}},
      required: [:course_id]
    }
  end

  @impl EMCP.Tool
  def call(conn, %{"course_id" => course_id}) do
    user = conn.assigns.current_user

    with {:ok, course} <- Content.get_course(user, course_id),
         {:ok, deleted} <- Content.soft_delete_course(user, course) do
      Errors.ok(Serializers.course(deleted))
    else
      error -> Errors.error(error)
    end
  end
end
