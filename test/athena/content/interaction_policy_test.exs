defmodule Athena.Content.InteractionPolicyTest do
  use Athena.DataCase, async: true
  import Athena.Factory

  alias Athena.Content.InteractionPolicy

  test "inherits through section ancestors; nearest explicit setting wins" do
    root = insert(:section, interaction_mode: :readonly)
    child = insert(:section, course: root.course, parent: root)
    inherited = insert(:block, section: child)
    writable = insert(:block, section: child, interaction_mode: :interactive)

    assert InteractionPolicy.readonly?(inherited)
    refute InteractionPolicy.readonly?(writable)

    assert InteractionPolicy.readonly_block_ids([inherited, writable]) ==
             MapSet.new([inherited.id])

    child =
      child |> Ecto.Changeset.change(interaction_mode: :interactive) |> Athena.Repo.update!()

    refute InteractionPolicy.readonly?(inherited)
    explicit = insert(:block, section: child, interaction_mode: :readonly)
    assert InteractionPolicy.block_readonly?(explicit.id)
  end

  test "inherit defaults to interactive and does not change visibility" do
    block = insert(:block, visibility: :hidden)
    refute InteractionPolicy.readonly?(block)
    refute Athena.Content.Policy.can_view?(nil, block)
    assert InteractionPolicy.readonly_block_ids([]) == MapSet.new()
  end
end
