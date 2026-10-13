defmodule Athena.Workers.UnblockExpiredAccountsTest do
  use Athena.DataCase, async: true

  alias Athena.Identity.Account
  alias Athena.Workers.{UnblockAccount, UnblockExpiredAccounts}
  import Athena.Factory

  defp expired_block do
    past = DateTime.add(DateTime.utc_now(:second), -1, :minute)

    insert(:account,
      status: :temporary_blocked,
      failed_login_attempts: 3,
      last_failed_at: past,
      blocked_until: past
    )
  end

  test "releases expired temporary blocks" do
    account = expired_block()

    pending =
      insert(:account,
        status: :temporary_blocked,
        blocked_until: DateTime.add(DateTime.utc_now(:second), 10, :minute)
      )

    assert :ok = perform_job(UnblockExpiredAccounts, %{})

    assert Repo.get!(Account, account.id).status == :active
    assert Repo.get!(Account, pending.id).status == :temporary_blocked
  end

  test "a legacy UnblockAccount job still releases expired blocks" do
    account = expired_block()

    assert :ok = perform_job(UnblockAccount, %{"account_id" => account.id})
    assert Repo.get!(Account, account.id).status == :active
  end

  test "a legacy UnblockAccount job for a missing account is a no-op" do
    assert :ok = perform_job(UnblockAccount, %{"account_id" => Ecto.UUID.generate()})
  end
end
