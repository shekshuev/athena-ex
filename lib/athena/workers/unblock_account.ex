defmodule Athena.Workers.UnblockAccount do
  @moduledoc """
  Deprecated: one-off unblock job from before temporary blocks carried their
  own expiry (`accounts.blocked_until`). Nothing enqueues it any more; it
  stays only so jobs already scheduled before the deploy still run, and just
  performs the regular sweep (`Athena.Workers.UnblockExpiredAccounts`).
  Remove once no `Athena.Workers.UnblockAccount` jobs remain in `oban_jobs`.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Athena.Identity

  @impl Oban.Worker
  def perform(_job) do
    Identity.unblock_expired_accounts()
    :ok
  end
end
