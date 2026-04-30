defmodule Athena.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :athena

  alias Athena.Repo
  alias Athena.Identity.{Roles, Accounts}

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  def create_admin(login, password) do
    load_app()

    Ecto.Migrator.with_repo(Repo, fn _repo ->
      Repo.transaction(fn ->
        role = ensure_admin_role()
        insert_admin_account(login, password, role.id)
      end)
    end)
  end

  defp ensure_admin_role do
    case Roles.get_role_by_name("admin") do
      {:ok, role} ->
        role

      {:error, :not_found} ->
        create_default_admin_role()
    end
  end

  defp create_default_admin_role do
    case Roles.system_create_role(%{"name" => "admin", "permissions" => ["admin"]}) do
      {:ok, role} ->
        role

      {:error, _} ->
        Repo.rollback("failed to create admin role")
    end
  end

  defp insert_admin_account(login, password, role_id) do
    attrs = %{"login" => login, "password" => password, "role_id" => role_id}

    case Accounts.create_account(attrs) do
      {:ok, _account} ->
        IO.puts("Admin #{login} created successfully!")

      {:error, _} ->
        IO.puts("Admin already exists or invalid data.")
    end
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
