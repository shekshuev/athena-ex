defmodule AthenaWeb.MCP.Tools.ListCourses do
  @moduledoc "MCP tool: list_courses."
  @behaviour EMCP.Tool

  alias Athena.Content
  alias AthenaWeb.MCP.Tools.{Errors, Serializers}

  @impl EMCP.Tool
  def name, do: "list_courses"

  @impl EMCP.Tool
  def description, do: "Lists courses visible to the authenticated account, paginated."

  @impl EMCP.Tool
  def input_schema do
    %{
      type: :object,
      properties: %{
        page: %{type: :integer},
        page_size: %{type: :integer}
      }
    }
  end

  @impl EMCP.Tool
  def call(conn, args) do
    user = conn.assigns.current_user
    params = Map.take(args, ["page", "page_size"])

    case Content.list_courses(user, params) do
      {:ok, {courses, meta}} ->
        Errors.ok(%{
          courses: Enum.map(courses, &Serializers.course/1),
          total_count: meta.total_count
        })

      error ->
        Errors.error(error)
    end
  end
end
