defmodule AthenaWeb.MCP.Tools.GetCourseTree do
  @moduledoc "MCP tool: get_course_tree."
  @behaviour EMCP.Tool

  alias Athena.Content
  alias AthenaWeb.MCP.Tools.{Errors, Serializers}

  @impl EMCP.Tool
  def name, do: "get_course_tree"

  @impl EMCP.Tool
  def description,
    do: "Returns a course's full section/block tree, unfiltered (same as the Studio Builder)."

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

    case Content.get_course(user, course_id) do
      {:ok, _course} ->
        tree = Content.get_course_tree(course_id)
        blocks_by_section = blocks_by_section(tree)

        Errors.ok(%{
          sections: Enum.map(tree, &Serializers.section(&1, blocks_by_section))
        })

      error ->
        Errors.error(error)
    end
  end

  defp blocks_by_section(tree) do
    tree
    |> section_ids()
    |> Content.list_blocks_by_section_ids()
    |> Enum.group_by(& &1.section_id)
  end

  defp section_ids(tree) do
    Enum.flat_map(tree, fn section -> [section.id | section_ids(section.children || [])] end)
  end
end
