defmodule Athena.Identity.Profiles do
  @moduledoc """
  Internal business logic for the Profile entity.

  Manages creation and updates of user profiles, ensuring 1-to-1 
  relationship constraints and emitting domain events via Oban outbox.
  """

  alias Athena.Repo
  alias Athena.Identity.Profile

  @doc """
  Retrieves a profile by its owner ID (Account ID).
  """
  @spec get_profile_by_owner(String.t()) :: {:ok, Profile.t()} | {:error, :not_found}
  def get_profile_by_owner(owner_id) do
    case Repo.get_by(Profile, owner_id: owner_id) do
      nil -> {:error, :not_found}
      profile -> {:ok, profile}
    end
  end

  @doc """
  Creates a new profile for an account and emits a ProfileUpdatedEvent.
  """
  @spec create_profile(String.t(), map()) :: {:ok, Profile.t()} | {:error, Ecto.Changeset.t()}
  def create_profile(owner_id, attrs) do
    attrs = Map.put(attrs, "owner_id", owner_id)

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:profile, Profile.changeset(%Profile{}, attrs))
    |> Repo.transaction()
    |> case do
      {:ok, %{profile: profile}} -> {:ok, profile}
      {:error, :profile, changeset, _} -> {:error, changeset}
    end
  end

  @doc """
  Updates an existing profile and emits a ProfileUpdatedEvent.
  """
  @spec update_profile(Profile.t(), map()) :: {:ok, Profile.t()} | {:error, Ecto.Changeset.t()}
  def update_profile(%Profile{} = profile, attrs) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(:profile, Profile.changeset(profile, attrs))
    |> Repo.transaction()
    |> case do
      {:ok, %{profile: updated_profile}} -> {:ok, updated_profile}
      {:error, :profile, changeset, _} -> {:error, changeset}
    end
  end
end
