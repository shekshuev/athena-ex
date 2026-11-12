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
    result =
      %{block_id: block.id}
      |> IndexBlockSearch.new(scheduled_at: block.search_due_at)
      |> Oban.insert()

    case result do
      {:ok, %Oban.Job{id: id}} when not is_nil(id) ->
        :ok

      _ ->
        # BasicEngine may report a unique conflict with no persisted job
        # when its advisory lock couldn't be acquired. That is not success.
        changeset
        |> Changeset.add_error(:base, "could not schedule search indexing")
        |> Repo.rollback()
    end
  end
end
