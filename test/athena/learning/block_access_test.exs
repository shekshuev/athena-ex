defmodule Athena.Learning.BlockAccessTest do
  use ExUnit.Case, async: true

  alias Athena.Content.{AccessRules, Block, CompletionRule}
  alias Athena.Learning

  test "a gate is visible and blocks later blocks until completed" do
    gate = block("gate", :button)
    later = block("later")
    assert Learning.visible_blocks([gate, later], []) == [gate]
    assert Learning.visible_blocks([gate, later], [gate.id]) == [gate, later]
  end

  test "a reset reopens the waterline and its own gate can block it again" do
    gate = block("gate", :button)
    hidden = block("hidden")
    reset = %{block("reset", :button) | access_rules: %AccessRules{reset_waterline: true}}
    later = block("later")

    assert Learning.visible_blocks([gate, hidden, reset, later], []) == [gate, reset]

    assert Learning.visible_blocks([gate, hidden, reset, later], [reset.id]) ==
             [gate, reset, later]
  end

  test "a later completion cannot bypass an earlier incomplete gate" do
    gate = block("gate", :button)
    later = block("later")
    assert Learning.visible_blocks([gate, later], [later.id]) == [gate]
  end

  defp block(id, type \\ :none),
    do: %Block{id: id, completion_rule: %CompletionRule{type: type}}
end
