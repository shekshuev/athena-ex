defmodule Athena.Engagement.Workers.PurgeStaleCheckpoints do
  @moduledoc """
  Periodic Oban cron job: removes orphaned exam proctoring checkpoints -
  rows left behind by attempts that were abandoned (a closed tab, a crash)
  and so never reached `finalize/1` to clean up their own checkpoint. A
  live, in-progress attempt rewrites its checkpoint about once a minute, so
  any row untouched for the TTL belongs to an attempt that is long over.

  The TTL defaults to 24h and can be overridden per-job via the
  `"older_than_seconds"` arg; the cron schedule is set in `runtime.exs`
  (`ENGAGEMENT_CHECKPOINT_PURGE_CRON`).
  """
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  alias Athena.Engagement.ProctoringCheckpoint

  @default_ttl_seconds 86_400

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    ttl_seconds = Map.get(args, "older_than_seconds", @default_ttl_seconds)
    ProctoringCheckpoint.purge_stale(ttl_seconds)
    :ok
  end
end
