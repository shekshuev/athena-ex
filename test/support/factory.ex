defmodule Athena.Factory do
  @moduledoc """
  ExMachina factory module
  """
  use ExMachina.Ecto, repo: Athena.Repo

  alias Athena.Identity.{Account, Role, Profile}
  alias Athena.Media.{File, Quota}

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

  def media_quota_factory do
    %Quota{
      role_id: Ecto.UUID.generate(),
      limit_bytes: 500 * 1024 * 1024
    }
  end

  def media_file_factory do
    %File{
      bucket: Application.get_env(:athena, Athena.Media)[:bucket] || "athena-test",
      key: sequence(:key, &"users/test_owner/files/doc_#{&1}.pdf"),
      original_name: "document.pdf",
      mime_type: "application/pdf",
      size: 1024 * 1024,
      context: :personal,
      owner_id: Ecto.UUID.generate()
    }
  end
end
