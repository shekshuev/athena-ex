defmodule AthenaWeb.MCP.Tools.SearchCourses do
  @moduledoc "MCP tool: search_courses_by_title."
  @behaviour EMCP.Tool

  alias Athena.Content
  alias AthenaWeb.MCP.Tools.{Errors, Serializers}

  @impl EMCP.Tool
  def name, do: "search_courses_by_title"

  @impl EMCP.Tool
  def description, do: "Searches courses visible to the authenticated account by title."

  @impl EMCP.Tool
  def input_schema do
    %{
      type: :object,
      properties: %{
        query: %{type: :string},
        limit: %{type: :integer}
      },
      required: [:query]
    }
  end

  @impl EMCP.Tool
  def call(conn, %{"query" => query} = args) do
    user = conn.assigns.current_user
    limit = args["limit"] || 10

    courses = Content.search_courses_by_title(user, query, limit)
    Errors.ok(%{courses: Enum.map(courses, &Serializers.course/1)})
  end
end
