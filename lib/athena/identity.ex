defmodule Athena.Identity do
  @moduledoc """
  Public API for Identity module
  """

  alias Athena.Identity.{Accounts, Roles, Account, Acl}

  defdelegate list_accounts(user, params \\ %{}, opts \\ []), to: Accounts
  defdelegate get_account(id, opts \\ []), to: Accounts
  defdelegate get_account_by_login(login), to: Accounts
  defdelegate authenticate(login, password), to: Accounts
  defdelegate register_admin_user(user, account_attrs, profile_attrs), to: Accounts
  defdelegate update_admin_user(user, account, account_attrs, profile_attrs), to: Accounts

  def soft_delete_account(account) do
    Accounts.soft_delete_account(account)
    |> notify_subscribers()
  end

  defp notify_subscribers({:ok, %Account{} = account} = result) do
    Phoenix.PubSub.broadcast(Athena.PubSub, "identity:events", {:account_deleted, account.id})
    result
  end

  defp notify_subscribers(result), do: result

  defdelegate login_regex(), to: Account
  defdelegate password_regex(), to: Account
  defdelegate get_accounts_map(ids), to: Accounts
  defdelegate search_accounts_by_login(user, query, limit), to: Accounts
  defdelegate force_change_password(account, attrs), to: Accounts
  defdelegate get_account_ids_by_login(query), to: Accounts

  defdelegate list_all_roles(user), to: Roles
  defdelegate get_role(user, id), to: Roles
  defdelegate get_role_by_name(name), to: Roles

  defdelegate can?(user, permission, resource \\ nil), to: Acl
  defdelegate can_any?(user, permissions), to: Acl
  defdelegate scope_query(query, user, permission), to: Acl
end
