defmodule Athena.Identity do
  @moduledoc """
  Public API for Identity module
  """

  use Boundary, exports: [Account, Role], deps: [Athena]

  alias Athena.Identity.{Accounts, Roles, Account}

  defdelegate get_account(id), to: Accounts
  defdelegate get_account_by_login(login), to: Accounts
  defdelegate authenticate(login, password), to: Accounts

  defdelegate get_role(id), to: Roles
  defdelegate get_role_by_name(name), to: Roles

  defdelegate login_regex(), to: Account
  defdelegate password_regex(), to: Account
end
