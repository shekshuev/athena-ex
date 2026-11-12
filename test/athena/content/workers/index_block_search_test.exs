defmodule Athena.Content.Workers.IndexBlockSearchTest do
  use Athena.DataCase, async: true

  import Athena.Factory

  alias Athena.Content.Block
  alias Athena.Content.Workers.IndexBlockSearch

  test "indexes an overdue block without changing content or updated_at" do
    block = insert(:block, content: doc("Новый текст"), search_text: "Old", search_due_at: past())

    assert :ok = perform_job(IndexBlockSearch, %{block_id: block.id})
    indexed = Repo.get!(Block, block.id)
    assert indexed.search_text == "Новый текст"
    assert is_nil(indexed.search_due_at)
    assert indexed.content == block.content
    assert indexed.updated_at == block.updated_at
    refute_enqueued(worker: IndexBlockSearch, args: %{block_id: block.id})
  end

  test "indexes a legacy block with no deadline and no search text" do
    block = insert(:block, content: doc("Legacy"))
    assert :ok = perform_job(IndexBlockSearch, %{block_id: block.id})
    assert Repo.get!(Block, block.id).search_text == "Legacy"
  end

  test "does not interpret an indexed empty string as missing text" do
    block = insert(:block, content: doc("Must not be rebuilt"), search_text: "")
    assert :ok = perform_job(IndexBlockSearch, %{block_id: block.id})
    assert Repo.get!(Block, block.id).search_text == ""
  end

  test "an early task snoozes without exposing the stale text as current" do
    due_at = DateTime.add(DateTime.utc_now(), 60)
    block = insert(:block, content: doc("New"), search_text: "Old", search_due_at: due_at)

    assert {:snooze, delay} = perform_job(IndexBlockSearch, %{block_id: block.id})
    assert delay in 1..60
    unchanged = Repo.get!(Block, block.id)
    assert unchanged.search_text == "Old"
    assert unchanged.search_due_at == due_at
  end

  test "a subsecond remainder is rounded up instead of becoming an immediate loop" do
    block = insert(:block, search_due_at: DateTime.add(DateTime.utc_now(), 900_000, :microsecond))
    assert {:snooze, 1} = perform_job(IndexBlockSearch, %{block_id: block.id})
  end

  test "missing and deleted blocks are successful no-ops" do
    assert :ok = perform_job(IndexBlockSearch, %{block_id: Ecto.UUID.generate()})
    block = insert(:block)
    Repo.delete!(block)
    assert :ok = perform_job(IndexBlockSearch, %{block_id: block.id})
  end

  test "duplicate execution leaves the already indexed block untouched" do
    block = insert(:block, content: doc("Once"), search_due_at: past())
    assert :ok = perform_job(IndexBlockSearch, %{block_id: block.id})
    first = Repo.get!(Block, block.id)
    assert :ok = perform_job(IndexBlockSearch, %{block_id: block.id})
    assert Repo.get!(Block, block.id) == first
  end

  test "changing to an excluded type clears previously indexed text" do
    block =
      insert(:block, type: :video, search_text: "Old searchable text", search_due_at: past())

    assert :ok = perform_job(IndexBlockSearch, %{block_id: block.id})
    assert %{search_text: "", search_due_at: nil} = Repo.get!(Block, block.id)
  end

  defp past, do: DateTime.add(DateTime.utc_now(), -1)

  defp doc(value) do
    %{
      "type" => "doc",
      "content" => [%{"type" => "paragraph", "content" => [%{"type" => "text", "text" => value}]}]
    }
  end
end
