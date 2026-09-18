defmodule AthenaWeb.MCP.Tools.DuplicateCourse do
  @moduledoc "MCP tool: duplicate_course."
  @behaviour EMCP.Tool

  alias Athena.Content
  alias AthenaWeb.MCP.Tools.{Errors, Serializers}

  @impl EMCP.Tool
  def name, do: "duplicate_course"

  @impl EMCP.Tool
  def description,
    do: "Deep-copies a course (sections, blocks, media) into a new draft course with a new title."

  @impl EMCP.Tool
  def input_schema do
    %{
      type: :object,
      properties: %{
        course_id: %{type: :string},
        new_title: %{type: :string}
      },
      required: [:course_id, :new_title]
    }
  end

  @impl EMCP.Tool
  def call(conn, %{"course_id" => course_id, "new_title" => new_title}) do
    user = conn.assigns.current_user

    case Content.duplicate_course(user, course_id, new_title) do
      {:ok, course} -> Errors.ok(Serializers.course(course))
      error -> Errors.error(error)
    end
  end
end
