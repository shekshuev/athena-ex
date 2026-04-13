defmodule Athena.Workers.UnblockAccountTest do
  use Athena.DataCase, async: true

  alias Athena.Workers.UnblockAccount
  alias Athena.Identity.Account
  import Athena.Factory

  describe "perform/1" do
    test "unblocks a temporarily blocked account and resets counters" do
      account =
        insert(:account,
          status: :temporary_blocked,
          failed_login_attempts: 3,
          last_failed_at: DateTime.utc_now(:second)
        )

      assert :ok = UnblockAccount.perform(%Oban.Job{args: %{"account_id" => account.id}})

      updated_account = Repo.get(Account, account.id)

      assert updated_account.status == :active
      assert updated_account.failed_login_attempts == 0
      assert updated_account.last_failed_at == nil
    end

    test "does nothing if the account is already active" do
      account = insert(:account, status: :active, failed_login_attempts: 1)

      assert :ok = UnblockAccount.perform(%Oban.Job{args: %{"account_id" => account.id}})

      updated_account = Repo.get(Account, account.id)

      assert updated_account.status == :active
      assert updated_account.failed_login_attempts == 1
    end

    test "does nothing if the account is permanently blocked" do
      account = insert(:account, status: :blocked, failed_login_attempts: 5)

      assert :ok = UnblockAccount.perform(%Oban.Job{args: %{"account_id" => account.id}})

      updated_account = Repo.get(Account, account.id)

      assert updated_account.status == :blocked
      assert updated_account.failed_login_attempts == 5
    end

    test "returns :ok and gracefully skips if account does not exist" do
      fake_id = Ecto.UUID.generate()
      assert :ok = UnblockAccount.perform(%Oban.Job{args: %{"account_id" => fake_id}})
    end
  end
end
