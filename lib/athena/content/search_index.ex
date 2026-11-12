defmodule Athena.Content.SearchIndex do
  @moduledoc """
  Persists blocks and schedules their derived search text atomically.

  Content writers use `insert/1` or `update/1` instead of writing directly
  through the repo. Search fields are internal and never cast from params.
  The block is written before the Oban job, keeping lock ordering consistent
  with the indexing worker. No text extraction runs in the caller.
  """

  alias Athena.Content.Block
  alias Athena.Content.Workers.IndexBlockSearch
  alias Athena.Repo
  alias Ecto.Changeset

  import Ecto.Query

  @debounce_seconds 60

  @spec insert(Block.t() | Changeset.t()) :: {:ok, Block.t()} | {:error, Changeset.t()}
  def insert(%Block{} = block), do: insert(Changeset.change(block))
  def insert(%Changeset{data: %Block{}} = changeset), do: persist(changeset, :insert)

  @spec update(Changeset.t()) :: {:ok, Block.t()} | {:error, Changeset.t()}
  def update(%Changeset{data: %Block{}} = changeset), do: persist(changeset, :update)

  @doc """
  Ensures a legacy or dirty block has a task, without postponing its deadline.

  Used by the manual backfill. Reads only indexing metadata under the same
  row lock as content writers. `rebuild?` also invalidates an otherwise
  current block. Executing jobs cannot suppress the required follow-up.
  """
  @spec ensure_scheduled(Ecto.UUID.t(), boolean()) ::
          {:ok, :enqueued | :pending | :current | :deleted} | {:error, :not_enqueued}
  def ensure_scheduled(block_id, rebuild? \\ false) when is_boolean(rebuild?) do
    Repo.transaction(fn ->
      block =
        Repo.one(
          from b in Block,
            where: b.id == ^block_id,
            select: %{id: b.id, search_due_at: b.search_due_at, missing?: is_nil(b.search_text)},
            lock: "FOR UPDATE"
        )

      cond do
        is_nil(block) -> :deleted
        not rebuild? and not block.missing? and is_nil(block.search_due_at) -> :current
        rebuild? and is_nil(block.search_due_at) -> schedule_backfill(block)
        pending_job?(block.id) -> :pending
        true -> schedule_backfill(block)
      end
    end)
  end

  @doc false
  def pending_jobs_count do
    IndexBlockSearch
    |> job_query()
    |> where([j], j.state in ["scheduled", "available", "executing", "retryable"])
    |> Repo.aggregate(:count)
  end

  defp pending_job?(block_id) do
    IndexBlockSearch
    |> job_query()
    |> where([j], j.state in ["scheduled", "available", "retryable"])
    |> where([j], fragment("? ->> 'block_id'", j.args) == ^block_id)
    |> Repo.exists?()
  end

  defp job_query(worker) do
    from j in Oban.Job, where: j.worker == ^Oban.Worker.to_string(worker)
  end

  defp schedule_backfill(block) do
    due_at = block.search_due_at || DateTime.utc_now()

    if is_nil(block.search_due_at) do
      from(b in Block, where: b.id == ^block.id)
      |> Repo.update_all(set: [search_due_at: due_at])
    end

    case insert_job(block.id, due_at) do
      {:ok, _job} -> :enqueued
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp persist(changeset, operation) do
    reindex? =
      operation == :insert or Enum.any?([:content, :type], &Changeset.changed?(changeset, &1))

    if reindex? and changeset.valid? do
      persist_indexed(changeset, operation)
    else
      apply(Repo, operation, [changeset])
    end
  end

  defp persist_indexed(changeset, operation) do
    Repo.transaction(fn ->
      if operation == :update do
        # Start the quiet period after acquiring the row, rather than
        # before a potentially long wait for another writer or extractor.
        id = Changeset.get_field(changeset, :id)
        Repo.one(from b in Block, where: b.id == ^id, select: b.id, lock: "FOR UPDATE")
      end

      due_at = DateTime.add(DateTime.utc_now(), @debounce_seconds, :second)
      changeset = Changeset.put_change(changeset, :search_due_at, due_at)

      block =
        case apply(Repo, operation, [changeset]) do
          {:ok, block} -> block
          {:error, reason} -> Repo.rollback(reason)
        end

      enqueue!(block, changeset)
      block
    end)
  end

  defp enqueue!(block, changeset) do
    case insert_job(block.id, block.search_due_at) do
      {:ok, _job} ->
        :ok

      _ ->
        # BasicEngine may report a unique conflict with no persisted job
        # when its advisory lock couldn't be acquired. That is not success.
        changeset
        |> Changeset.add_error(:base, "could not schedule search indexing")
        |> Repo.rollback()
    end
  end

  defp insert_job(block_id, due_at) do
    result =
      %{block_id: block_id}
      |> IndexBlockSearch.new(scheduled_at: due_at)
      |> Oban.insert()

    case result do
      {:ok, %Oban.Job{id: id} = job} when not is_nil(id) -> {:ok, job}
      _ -> {:error, :not_enqueued}
    end
  end
end
