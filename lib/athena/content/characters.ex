defmodule Athena.Content.Characters do
  @moduledoc """
  Internal business logic for reusable storytelling Characters (name + avatar),
  used by dialogue nodes inside Tiptap-based blocks.
  """

  import Ecto.Query
  alias Athena.{Repo, Identity, Media}
  alias Athena.Identity.Acl
  alias Athena.Content.Character

  @doc "Lists a user's characters with Flop pagination, scoped by ACL (own_only)."
  @spec list_characters(map(), map()) ::
          {:ok, {[Character.t()], Flop.Meta.t()}} | {:error, Flop.Meta.t()}
  def list_characters(user, params \\ %{}) do
    Character
    |> Acl.scope_query(user, "characters.read")
    |> Flop.validate_and_run(params, for: Character)
  end

  @doc "Returns all characters visible to the user, unpaginated (for editor pickers)."
  @spec all_characters(map()) :: [Character.t()]
  def all_characters(user) do
    Character
    |> Acl.scope_query(user, "characters.read")
    |> order_by([c], asc: c.name)
    |> Repo.all()
  end

  @doc """
  Returns the user's characters as plain JSON-friendly maps
  (`id`, `name`, `avatarUrl`, `color`) for the Tiptap dialogue picker.
  """
  @spec characters_for_picker(map()) :: [map()]
  def characters_for_picker(user) do
    user
    |> all_characters()
    |> Enum.map(fn character ->
      %{
        id: character.id,
        name: character.name,
        avatarUrl: avatar_url(character.avatar_file_id),
        color: character.color
      }
    end)
  end

  defp avatar_url(nil), do: nil

  defp avatar_url(file_id) do
    case Media.get_file(file_id) do
      nil -> nil
      file -> "/media/#{file.key}"
    end
  end

  @doc "Retrieves a single character, scoped by ACL."
  @spec get_character(map(), String.t()) :: {:ok, Character.t()} | {:error, :not_found}
  def get_character(user, id) do
    Character
    |> where([c], c.id == ^id)
    |> Acl.scope_query(user, "characters.read")
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      character -> {:ok, character}
    end
  end

  @doc "Creates a new character owned by the current user."
  @spec create_character(map(), map()) ::
          {:ok, Character.t()} | {:error, Ecto.Changeset.t() | :forbidden}
  def create_character(user, attrs) do
    if Identity.can?(user, "characters.create") do
      %Character{owner_id: user.id}
      |> Character.changeset(attrs)
      |> Repo.insert()
    else
      {:error, :forbidden}
    end
  end

  @doc "Updates a character. Checks own_only policies."
  @spec update_character(map(), Character.t(), map()) ::
          {:ok, Character.t()} | {:error, Ecto.Changeset.t() | :forbidden}
  def update_character(user, %Character{} = character, attrs) do
    if Identity.can?(user, "characters.update", character) do
      old_avatar_file_id = character.avatar_file_id

      case character |> Character.changeset(attrs) |> Repo.update() do
        {:ok, updated} = result ->
          maybe_cleanup_avatar(old_avatar_file_id, updated.avatar_file_id)
          result

        error ->
          error
      end
    else
      {:error, :forbidden}
    end
  end

  @doc "Deletes a character. Checks own_only policies."
  @spec delete_character(map(), Character.t()) ::
          {:ok, Character.t()} | {:error, Ecto.Changeset.t() | :forbidden}
  def delete_character(user, %Character{} = character) do
    if Identity.can?(user, "characters.delete", character) do
      case Repo.delete(character) do
        {:ok, deleted} = result ->
          maybe_cleanup_avatar(deleted.avatar_file_id, nil)
          result

        error ->
          error
      end
    else
      {:error, :forbidden}
    end
  end

  @doc """
  Generates a presigned upload URL for a character avatar, namespaced by owner
  (not tied to a course, unlike course-material uploads).
  """
  @spec prepare_avatar_upload(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def prepare_avatar_upload(user, filename) do
    bucket = Application.get_env(:athena, Media)[:bucket] || "athena"
    unique_filename = "#{Ecto.UUID.generate()}-#{filename}"
    key = "avatars/#{user.id}/#{unique_filename}"

    case Media.generate_upload_url(bucket, key) do
      {:ok, presigned_url} ->
        {:ok,
         %{
           uploader: "S3",
           url: presigned_url,
           url_for_saved_entry: "/media/#{key}",
           bucket: bucket,
           key: key
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_cleanup_avatar(old_file_id, new_file_id)
       when is_binary(old_file_id) and old_file_id != new_file_id do
    case Repo.get(Media.File, old_file_id) do
      nil -> :ok
      file -> Media.delete_file(file)
    end
  end

  defp maybe_cleanup_avatar(_old_file_id, _new_file_id), do: :ok
end
