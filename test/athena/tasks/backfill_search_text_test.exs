defmodule Athena.Tasks.BackfillSearchTextTest do
  use Athena.DataCase, async: true

  import Athena.Factory

  alias Athena.Content.{Block, SearchIndex}
  alias Athena.Content.Workers.IndexBlockSearch
  alias Athena.Tasks.BackfillSearchText

  setup do
    %{section: insert(:section)}
  end

  test "an empty database is a completed planning pass" do
    assert {:ok, %{status: :complete, scanned: 0, enqueued: 0, after_id: nil}} =
             BackfillSearchText.run()
  end

  test "schedules several small batches and a repeat does not duplicate their jobs", ctx do
    blocks = for _ <- 1..5, do: legacy(ctx.section)

    assert {:ok, first} = BackfillSearchText.run(batch_size: 2)
    assert %{status: :complete, scanned: 5, enqueued: 5, skipped: 0, batches: 3} = first
    assert first.after_id == blocks |> Enum.map(& &1.id) |> Enum.max()

    assert {:ok, %{status: :complete, scanned: 5, enqueued: 0, pending: 5, skipped: 5}} =
             BackfillSearchText.run(batch_size: 2)

    assert SearchIndex.pending_jobs_count() == 5

    assert %{success: 5, failure: 0} =
             Oban.drain_queue(queue: :search_index, with_scheduled: true)

    assert {:ok, %{status: :complete, scanned: 0, enqueued: 0}} = BackfillSearchText.run()
    assert Enum.all?(blocks, &(Repo.get!(Block, &1.id).search_text == "Legacy"))
  end

  test "a per-run limit returns a cursor that resumes without re-enqueueing earlier blocks",
       ctx do
    for _ <- 1..5, do: legacy(ctx.section)

    assert {:ok, %{status: :limit_reached, scanned: 2, enqueued: 2} = first} =
             BackfillSearchText.run(limit: 2)

    assert {:ok, %{status: :complete, scanned: 3, enqueued: 3}} =
             BackfillSearchText.run(after_id: first.after_id)

    assert SearchIndex.pending_jobs_count() == 5
  end

  test "stops at the indexing backlog and resumes after workers free capacity", ctx do
    for _ <- 1..5, do: legacy(ctx.section)

    assert {:ok, %{status: :queue_full, enqueued: 2, scanned: 2} = first} =
             BackfillSearchText.run(max_pending_jobs: 2, batch_size: 5)

    assert {:ok, %{status: :queue_full, scanned: 0, after_id: cursor}} =
             BackfillSearchText.run(max_pending_jobs: 2, after_id: first.after_id)

    assert cursor == first.after_id

    assert %{success: 2, failure: 0} =
             Oban.drain_queue(queue: :search_index, with_scheduled: true)

    assert {:ok, %{status: :queue_full, enqueued: 2} = second} =
             BackfillSearchText.run(max_pending_jobs: 2, after_id: cursor)

    assert %{success: 2, failure: 0} =
             Oban.drain_queue(queue: :search_index, with_scheduled: true)

    assert {:ok, %{status: :complete, enqueued: 1}} =
             BackfillSearchText.run(max_pending_jobs: 2, after_id: second.after_id)
  end

  test "other workers do not consume the indexing backlog budget", ctx do
    legacy(ctx.section)
    Oban.insert!(Athena.Workers.MediaCleanup.new(%{}))

    assert {:ok, %{status: :complete, enqueued: 1}} =
             BackfillSearchText.run(max_pending_jobs: 1)
  end

  test "an active edit keeps its deadline and its existing scheduled task", ctx do
    {:ok, block} = SearchIndex.insert(build(:block, section: ctx.section, content: doc()))
    [job] = jobs(block)

    assert {:ok, %{enqueued: 0, pending: 1}} = BackfillSearchText.run(rebuild: true)
    assert Repo.get!(Block, block.id).search_due_at == block.search_due_at
    assert [same_job] = jobs(block)
    assert same_job.id == job.id
    assert same_job.scheduled_at == job.scheduled_at
  end

  test "restores a missing future task at its original deadline", ctx do
    due_at = DateTime.add(DateTime.utc_now(), 120)
    block = insert(:block, section: ctx.section, content: doc(), search_due_at: due_at)

    assert {:ok, %{enqueued: 1}} = BackfillSearchText.run()
    assert Repo.get!(Block, block.id).search_due_at == due_at
    assert [job] = jobs(block)
    assert job.scheduled_at == due_at
  end

  test "restores overdue work after cancellation, discard or a completed obsolete task", ctx do
    blocks =
      for state <- ~w(cancelled discarded completed) do
        block = insert(:block, section: ctx.section, content: doc(), search_due_at: past())
        {:ok, job} = Oban.insert(IndexBlockSearch.new(%{block_id: block.id}))
        job |> change(state: state) |> Repo.update!()
        block
      end

    assert {:ok, %{enqueued: 3}} = BackfillSearchText.run()

    assert %{success: 3, failure: 0} =
             Oban.drain_queue(queue: :search_index, with_scheduled: true)

    assert Enum.all?(blocks, &(Repo.get!(Block, &1.id).search_text == "Legacy"))
  end

  test "retrying and available work is preserved; executing work gets a safe follow-up", ctx do
    for state <- ~w(retryable available executing) do
      block = insert(:block, section: ctx.section, content: doc(), search_due_at: past())
      {:ok, job} = Oban.insert(IndexBlockSearch.new(%{block_id: block.id}))
      job |> change(state: state) |> Repo.update!()
    end

    assert {:ok, %{enqueued: 1, pending: 2, skipped: 2}} = BackfillSearchText.run()
  end

  test "ordinary runs skip current texts, including indexed empty strings", ctx do
    insert(:block, section: ctx.section, search_text: "Current")
    insert(:block, section: ctx.section, type: :video, search_text: "")
    assert {:ok, %{scanned: 0, enqueued: 0}} = BackfillSearchText.run()
  end

  test "rebuild invalidates current text without changing content or updated_at", ctx do
    block =
      insert(:block, section: ctx.section, content: doc(), search_text: "Old extractor output")

    assert {:ok, %{enqueued: 1}} = BackfillSearchText.run(rebuild: true)
    stale = Repo.get!(Block, block.id)
    assert stale.search_text == "Old extractor output"
    assert stale.search_due_at
    assert stale.updated_at == block.updated_at
    assert stale.content == block.content

    assert %{success: 1, failure: 0} =
             Oban.drain_queue(queue: :search_index, with_scheduled: true)

    assert %{search_text: "Legacy", search_due_at: nil} = Repo.get!(Block, block.id)
  end

  test "a rebuild cursor skips already rebuilt blocks when resuming", ctx do
    for _ <- 1..3, do: insert(:block, section: ctx.section, content: doc(), search_text: "Old")

    assert {:ok, %{status: :limit_reached, after_id: cursor}} =
             BackfillSearchText.run(rebuild: true, limit: 1)

    assert %{success: 1, failure: 0} =
             Oban.drain_queue(queue: :search_index, with_scheduled: true)

    assert {:ok, %{status: :complete, scanned: 2, enqueued: 2}} =
             BackfillSearchText.run(rebuild: true, after_id: cursor)

    assert length(jobs(%Block{id: cursor})) == 1
  end

  test "a fresh pass picks up UUIDs inserted before an earlier cursor", ctx do
    [low, mid, high] = Enum.sort(for _ <- 1..3, do: Ecto.UUID.generate())
    insert(:block, section: ctx.section, id: mid, content: doc())
    insert(:block, section: ctx.section, id: high, content: doc())

    assert {:ok, %{after_id: ^mid}} = BackfillSearchText.run(limit: 1)
    low_block = insert(:block, section: ctx.section, id: low, content: doc())
    assert {:ok, %{enqueued: 1}} = BackfillSearchText.run(after_id: mid)
    assert jobs(low_block) == []
    assert {:ok, %{enqueued: 1, pending: 2}} = BackfillSearchText.run()
    assert [_] = jobs(low_block)
  end

  test "status distinguishes scheduling from completed indexing", ctx do
    legacy(ctx.section)
    insert(:block, section: ctx.section, search_text: "Current")
    assert %{unindexed: 1, dirty: 0, needs_indexing: 1} = BackfillSearchText.status()

    assert {:ok, %{status: :complete}} = BackfillSearchText.run()

    assert %{unindexed: 1, dirty: 1, needs_indexing: 1, jobs: %{"scheduled" => 1}} =
             BackfillSearchText.status()

    assert %{success: 1, failure: 0} =
             Oban.drain_queue(queue: :search_index, with_scheduled: true)

    assert %{unindexed: 0, dirty: 0, needs_indexing: 0, jobs: %{"completed" => 1}} =
             BackfillSearchText.status()
  end

  test "invalid or misspelled options fail before scheduling", ctx do
    block = legacy(ctx.section)

    for opts <- [
          [batch_size: 0],
          [batch_size: 1001],
          [limit: -1],
          [max_pending_jobs: 0],
          [after_id: "wrong"],
          [rebuild: "true"],
          [batc_size: 5]
        ] do
      assert_raise ArgumentError, fn -> BackfillSearchText.run(opts) end
    end

    assert jobs(block) == []
    assert is_nil(Repo.get!(Block, block.id).search_due_at)
  end

  defp legacy(section), do: insert(:block, section: section, content: doc())
  defp past, do: DateTime.add(DateTime.utc_now(), -1)

  defp jobs(block) do
    Repo.all(
      from j in Oban.Job,
        where: j.worker == ^Oban.Worker.to_string(IndexBlockSearch),
        where: fragment("? ->> 'block_id'", j.args) == ^block.id
    )
  end

  defp doc do
    %{
      "type" => "doc",
      "content" => [
        %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "Legacy"}]}
      ]
    }
  end
end
