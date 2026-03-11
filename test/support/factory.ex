defmodule Athena.Factory do
  use ExMachina.Ecto, repo: Athena.Repo

  alias Athena.Identity.{Account, Role, Profile}

  def role_factory do
    %Role{
      name: sequence(:name, &"Role #{&1}"),
      permissions: ["read:courses", "write:courses"],
      policies: %{}
    }
  end

  def account_factory do
    %Account{
      login: sequence(:login, &"test_user_#{&1}"),
      password_hash: Argon2.hash_pwd_salt("Password123!"),
      status: :active,
      role: build(:role)
    }
  end

  def profile_factory do
    %Profile{
      first_name: "John",
      last_name: sequence(:last_name, &"Doe #{&1}"),
      owner: build(:account)
    }
  end
end
