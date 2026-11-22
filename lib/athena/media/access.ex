defmodule Athena.Media.Access do
  @moduledoc "Download authorization, delegated to each resource's owning context."

  alias Athena.{Content, Learning, Media}

  def allowed?(%{status: :active} = user, key) when is_binary(key) do
    valid_key?(key) and authorized?(user, key)
  end

  def allowed?(_user, _key), do: false

  defp authorized?(user, key) do
    case Media.get_file_by_key(key) do
      %{context: :personal} = file ->
        Media.can_download_personal_file?(user.id, file)

      %{context: :avatar} ->
        true

      %{owner_id: owner_id} when owner_id == user.id ->
        true

      _ ->
        own_pending_upload?(user, key) or resource_access?(user, key)
    end
  end

  defp resource_access?(user, key) do
    case Content.media_download_access(user, key) do
      :allowed ->
        true

      :denied ->
        Learning.can_download_exam_media?(user, key)

      :unknown ->
        Learning.can_download_exam_media?(user, key) or submission_access?(user, key)
    end
  end

  defp submission_access?(user, key) do
    case String.split(key, "/") do
      [prefix | _] when prefix in ["courses", "submissions"] ->
        Learning.can_download_submission_media?(user, key)

      _ ->
        false
    end
  end

  defp own_pending_upload?(user, key) do
    case String.split(key, "/") do
      [prefix, owner_id | _] when prefix in ["avatars", "submissions", "library"] ->
        owner_id == user.id

      _ ->
        false
    end
  end

  defp valid_key?(key) do
    key != "" and not String.starts_with?(key, "/") and
      not String.contains?(key, ["\\", "\0"]) and
      Enum.all?(String.split(key, "/"), &(&1 not in ["", ".", ".."]))
  end
end
