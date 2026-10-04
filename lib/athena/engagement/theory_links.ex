defmodule Athena.Engagement.TheoryLinks do
  @moduledoc """
  Which content ("theory") a graded task builds on, so a low score can be
  read next to how the student went through that material.

  There is no explicit link in the course model, so it is inferred from
  position: the non-graded blocks (text, video, image, attachment) between
  the previous graded block of the same section and this one. A task with
  nothing in front of it in its own section (a section that opens with a
  quiz) falls back to the non-graded blocks of the section right before it.
  """

  alias Athena.Content.Block

  @doc """
  Theory blocks for `block`, in course order. `sections` is the course's
  sections in course order and `blocks_by_section` their blocks sorted by
  `order` - the shape `Athena.Engagement.Metrics` already builds.
  """
  @spec theory_blocks_for(Block.t(), [map()], %{binary() => [Block.t()]}) :: [Block.t()]
  def theory_blocks_for(%Block{} = block, sections, blocks_by_section) do
    siblings = Map.get(blocks_by_section, block.section_id, [])

    case theory_before(block, siblings) do
      [] -> previous_section_theory(block.section_id, sections, blocks_by_section)
      theory -> theory
    end
  end

  # Walking back from the task, collect content blocks until the previous
  # graded block (the material that "belongs" to an earlier task).
  defp theory_before(block, siblings) do
    siblings
    |> Enum.filter(&(&1.order < block.order))
    |> Enum.reverse()
    |> Enum.take_while(&(not Block.gradable?(&1)))
    |> Enum.reverse()
  end

  defp previous_section_theory(section_id, sections, blocks_by_section) do
    index = Enum.find_index(sections, &(&1.id == section_id))

    if index && index > 0 do
      previous = Enum.at(sections, index - 1)
      blocks_by_section |> Map.get(previous.id, []) |> Enum.reject(&Block.gradable?/1)
    else
      []
    end
  end
end
