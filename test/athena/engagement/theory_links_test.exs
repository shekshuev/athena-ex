defmodule Athena.Engagement.TheoryLinksTest do
  use ExUnit.Case, async: true

  alias Athena.Content.Block
  alias Athena.Engagement.TheoryLinks

  defp block(id, section_id, type, order),
    do: %Block{id: id, section_id: section_id, type: type, order: order}

  setup do
    s1 = %{id: "s1"}
    s2 = %{id: "s2"}

    blocks_by_section = %{
      "s1" => [
        block("t1", "s1", :text, 10),
        block("v1", "s1", :video, 20),
        block("q1", "s1", :quiz_question, 30),
        block("t2", "s1", :text, 40),
        block("c1", "s1", :code, 50)
      ],
      "s2" => [block("e1", "s2", :quiz_exam, 10), block("t3", "s2", :text, 20)]
    }

    %{sections: [s1, s2], blocks_by_section: blocks_by_section}
  end

  defp theory_ids(id, ctx) do
    block = ctx.blocks_by_section |> Map.values() |> List.flatten() |> Enum.find(&(&1.id == id))

    block
    |> TheoryLinks.theory_blocks_for(ctx.sections, ctx.blocks_by_section)
    |> Enum.map(& &1.id)
  end

  test "the content right before a task, up to the previous task", ctx do
    assert theory_ids("q1", ctx) == ["t1", "v1"]
    assert theory_ids("c1", ctx) == ["t2"]
  end

  test "a task that opens its section uses the previous section's content", ctx do
    assert theory_ids("e1", ctx) == ["t1", "v1", "t2"]
  end

  test "a task at the very start of the course has no theory", ctx do
    ctx = %{
      ctx
      | blocks_by_section: %{
          ctx.blocks_by_section
          | "s1" => [block("q0", "s1", :quiz_question, 1)]
        }
    }

    assert theory_ids("q0", ctx) == []
  end
end
