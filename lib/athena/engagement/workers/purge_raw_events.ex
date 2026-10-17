defmodule Athena.Engagement.Workers.PurgeRawEvents do
  @moduledoc """
  Oban job carrying out one `Athena.Engagement.Purge`: waits (snoozing)
  until the rollups hold everything being deleted, then deletes the raw
  events in batches (`Athena.Engagement.Purges.run/1`).
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 5

  alias Athena.Engagement.{Purge, Purges}
  alias Athena.Repo

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(30)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"purge_id" => purge_id}}) do
    case Repo.get(Purge, purge_id) do
      nil -> :ok
      purge -> Purges.run(purge)
    end
  end
end
