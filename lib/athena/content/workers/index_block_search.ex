defmodule Athena.Content.Workers.IndexBlockSearch do
  @moduledoc """
  Refreshes a block's search text after its content has stopped changing.

  Only scheduled jobs are deduplicated. An available, executing or retrying
  job must not swallow the follow-up needed by a new edit. Every invocation
  rechecks the persisted deadline under a row lock, so early and duplicate
  executions are harmless. Retries may coexist with a newer scheduled job.
  """

  use Oban.Worker,
    queue: :search_index,
    max_attempts: 5,
    unique: [period: :infinity, keys: [:block_id], states: [:scheduled]],
    replace: [scheduled: [:scheduled_at]]

  import Ecto.Query

  alias Athena.Content.{Block, TextExtractor}
  alias Athena.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"block_id" => block_id}}) do
    case Repo.transaction(fn -> refresh(block_id) end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp refresh(block_id) do
    block = Repo.one(from b in Block, where: b.id == ^block_id, lock: "FOR UPDATE")

    case block do
      nil -> :ok
      %Block{search_due_at: nil, search_text: text} when is_binary(text) -> :ok
      block -> refresh_due(block)
    end
  end

  defp refresh_due(block) do
    now = DateTime.utc_now()

    if block.search_due_at && DateTime.compare(block.search_due_at, now) == :gt do
      remaining_us = DateTime.diff(block.search_due_at, now, :microsecond)
      {:snooze, div(remaining_us + 999_999, 1_000_000)}
    else
      text = TextExtractor.extract(block)

      # Deliberately bypass content changesets and timestamps: this is a
      # derived-field write, not another edit or an indexing notification.
      from(b in Block, where: b.id == ^block.id)
      |> Repo.update_all(set: [search_text: text, search_due_at: nil])

      :ok
    end
  end
end
