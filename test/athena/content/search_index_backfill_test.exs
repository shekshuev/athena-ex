defmodule Athena.Content.SearchIndexBackfillTest do
  use Athena.DataCase, async: true

  import Athena.Factory

  alias Athena.Content.{Block, SearchIndex}
  alias Athena.Content.Workers.IndexBlockSearch

  test "an already indexed block and a deleted block are safe no-ops" do
    block = insert(:block, search_text: "Current")
    assert {:ok, :current} = SearchIndex.ensure_scheduled(block.id)
    assert {:ok, :deleted} = SearchIndex.ensure_scheduled(Ecto.UUID.generate())
    refute_enqueued(worker: IndexBlockSearch)
  end

  test "an enclosing rollback restores the marker and removes the backfill job" do
    block = insert(:block, search_text: "Old")

    assert {:error, :abort} =
             Repo.transaction(fn ->
               assert {:ok, :enqueued} = SearchIndex.ensure_scheduled(block.id, true)
               Repo.rollback(:abort)
             end)

    assert is_nil(Repo.get!(Block, block.id).search_due_at)
    refute_enqueued(worker: IndexBlockSearch, args: %{block_id: block.id})
  end

  test "backfill reads metadata rather than content or the full search text" do
    block = insert(:block, search_text: String.duplicate("Large", 1000))
    ref = make_ref()
    handler = {__MODULE__, ref}

    :ok =
      :telemetry.attach(
        handler,
        [:athena, :repo, :query],
        &__MODULE__.collect_query/4,
        {self(), ref}
      )

    try do
      assert {:ok, :enqueued} = SearchIndex.ensure_scheduled(block.id, true)
    after
      :telemetry.detach(handler)
    end

    queries = collect_queries(ref)
    refute Enum.any?(queries, &String.contains?(&1, ~s(b0."content")))
    assert Enum.any?(queries, &String.contains?(&1, ~s|b0."search_text" IS NULL|))
  end

  @doc false
  def collect_query(_event, _measurements, metadata, {owner, ref}) do
    if self() == owner, do: send(owner, {ref, metadata.query})
  end

  defp collect_queries(ref) do
    receive do
      {^ref, query} -> [query | collect_queries(ref)]
    after
      0 -> []
    end
  end
end
