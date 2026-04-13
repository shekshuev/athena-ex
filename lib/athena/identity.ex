defmodule Athena.Identity do
  @moduledoc """
  Public API for Identity module
  """

  alias Athena.Identity.{Accounts, Roles, Account, Acl}

  defdelegate list_accounts(params \\ %{}, opts \\ []), to: Accounts
  defdelegate get_account(id, opts \\ []), to: Accounts
  defdelegate get_account_by_login(login), to: Accounts
  defdelegate authenticate(login, password), to: Accounts
  defdelegate register_admin_user(account_attrs, profile_attrs), to: Accounts
  defdelegate update_admin_user(account, account_attrs, profile_attrs), to: Accounts
  defdelegate soft_delete_account(account), to: Accounts
  defdelegate login_regex(), to: Account
  defdelegate password_regex(), to: Account
  defdelegate get_accounts_map(ids), to: Accounts
  defdelegate search_accounts_by_login(query, limit), to: Accounts
  defdelegate force_change_password(account, attrs), to: Accounts

  defdelegate list_all_roles(), to: Roles
  defdelegate get_role(id), to: Roles
  defdelegate get_role_by_name(name), to: Roles

  defdelegate can?(user, permission, resource \\ nil), to: Acl
  defdelegate can_any?(user, permissions), to: Acl
end
