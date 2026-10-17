defmodule Athena.Workers.UnblockExpiredAccounts do
  @moduledoc """
  Oban cron job that lifts temporary account blocks whose `blocked_until`
  has passed (`Athena.Identity.unblock_expired_accounts/0`).

  A blocked user is also released on their next login attempt after the
  expiry, so this sweep only makes the admin list show the real status.
  """
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  require Logger
  alias Athena.Identity

  @impl Oban.Worker
  def perform(_job) do
    count = Identity.unblock_expired_accounts()
    if count > 0, do: Logger.info("[UnblockExpiredAccounts] released #{count} account(s)")
    :ok
  end
end
