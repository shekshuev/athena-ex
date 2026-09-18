defmodule AthenaWeb.MCP.Tools.Serializers do
  @moduledoc """
  Builds small, JSON-encodable maps from `Athena.Content` structs for MCP
  tool responses. Ecto structs aren't `Jason.Encoder`-derived (association
  fields, `__meta__`, etc. aren't serializable), so tools never
  `Jason.encode!/1` a struct directly — they go through one of these.
  """

  alias Athena.Content.{Block, Course, LibraryBlock, Section}

  def course(%Course{} = course) do
    %{
      id: course.id,
      title: course.title,
      description: course.description,
      status: course.status,
      type: course.type,
      owner_id: course.owner_id,
      is_public: course.is_public,
      code: course.code
    }
  end

  def section(%Section{} = section, blocks_by_section \\ %{}) do
    %{
      id: section.id,
      title: section.title,
      order: section.order,
      visibility: section.visibility,
      course_id: section.course_id,
      parent_id: section.parent_id,
      access_rules: embed(section.access_rules),
      engagement_rule: embed(section.engagement_rule),
      blocks: Enum.map(Map.get(blocks_by_section, section.id, []), &block/1),
      children: Enum.map(section.children || [], &section(&1, blocks_by_section))
    }
  end

  def block(%Block{} = block) do
    %{
      id: block.id,
      type: block.type,
      content: block.content,
      order: block.order,
      visibility: block.visibility,
      section_id: block.section_id,
      access_rules: embed(block.access_rules),
      completion_rule: embed(block.completion_rule),
      engagement_rule: embed(block.engagement_rule)
    }
  end

  # Embedded schemas (AccessRules/CompletionRule/EngagementRule) aren't
  # `Jason.Encoder`-derived, so convert them to plain maps before including
  # them in a tool response - `nil` (never set) and `Ecto.Association.NotLoaded`
  # (not preloaded, shouldn't happen for embeds but stay defensive) both become `nil`.
  defp embed(nil), do: nil
  defp embed(%{__struct__: _} = struct), do: struct |> Map.from_struct() |> Map.delete(:__meta__)
  defp embed(_not_loaded), do: nil

  def library_block(%LibraryBlock{} = library_block) do
    %{
      id: library_block.id,
      title: library_block.title,
      type: library_block.type,
      content: library_block.content,
      tags: library_block.tags,
      owner_id: library_block.owner_id,
      is_public: library_block.is_public
    }
  end
end
