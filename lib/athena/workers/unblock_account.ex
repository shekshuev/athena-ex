defmodule Athena.Workers.UnblockAccount do
  @moduledoc """
  Oban worker that removes temporary blocks from user accounts.
  Triggered automatically after a specified timeout period when an account
  is blocked due to too many failed login attempts.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger
  alias Athena.Identity
  alias Athena.Identity.Accounts

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"account_id" => id}}) do
    Logger.info("[UnblockAccount] Processing unblock request for account_id: #{id}...")

    case Identity.get_account(id) do
      {:ok, account} ->
        process_account(account)

      {:error, :not_found} ->
        Logger.warning("[UnblockAccount] Account #{id} not found. Skipping.")
        :ok
    end
  end

  @doc false
  defp process_account(%{status: :temporary_blocked} = account) do
    Logger.info("[UnblockAccount] Account #{account.id} is temporarily blocked. Unblocking...")

    case Accounts.update_account(account, %{
           status: :active,
           failed_login_attempts: 0,
           last_failed_at: nil
         }) do
      {:ok, _updated_account} ->
        Logger.info("[UnblockAccount] Account #{account.id} successfully unblocked.")
        :ok

      {:error, err} ->
        Logger.error("[UnblockAccount] Failed to unblock account #{account.id}: #{inspect(err)}")
        {:error, err}
    end
  end

  defp process_account(account) do
    Logger.info(
      "[UnblockAccount] Account #{account.id} has status :#{account.status}. No action needed."
    )

    :ok
  end
end
