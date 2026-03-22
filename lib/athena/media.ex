defmodule Athena.Media do
  @moduledoc """
  Business logic for Media and S3 integrations.
  """

  import Ecto.Query
  alias Athena.Repo
  alias Athena.Media.{File, Quota}

  @default_quota_bytes 100 * 1024 * 1024

  @doc """
  Retrieves a paginated list of files.
  """
  @spec list_files(map()) :: {:ok, {[File.t()], Flop.Meta.t()}} | {:error, Flop.Meta.t()}
  def list_files(params \\ %{}) do
    Flop.validate_and_run(File, params, for: File)
  end

  @doc """
  Sets or updates the storage quota for a role.
  """
  @spec set_quota(String.t(), integer()) :: {:ok, Quota.t()} | {:error, Ecto.Changeset.t()}
  def set_quota(role_id, limit_bytes) do
    %Quota{role_id: role_id}
    |> Quota.changeset(%{limit_bytes: limit_bytes})
    |> Repo.insert(
      on_conflict: {:replace, [:limit_bytes, :updated_at]},
      conflict_target: :role_id
    )
  end

  @doc """
  Deletes the quota setting for a role (fallback to default).
  """
  @spec delete_quota(String.t()) :: {integer(), nil | [term()]}
  def delete_quota(role_id) do
    Repo.delete_all(where(Quota, role_id: ^role_id))
  end

  @doc """
  Gets the current storage usage and limit for a user's personal files.
  """
  @spec get_usage(String.t(), String.t()) :: %{used: integer(), limit: integer()}
  def get_usage(owner_id, role_id) do
    limit =
      case Repo.get(Quota, role_id) do
        nil -> @default_quota_bytes
        %Quota{limit_bytes: bytes} -> bytes
      end

    used =
      File
      |> where([f], f.owner_id == ^owner_id and f.context == :personal)
      |> select([f], sum(f.size))
      |> Repo.one()
      |> case do
        nil -> 0
        %Decimal{} = d -> Decimal.to_integer(d)
        int when is_integer(int) -> int
      end

    %{used: used, limit: limit}
  end

  @doc """
  Checks if the user has enough space to upload a personal file.
  Returns `:ok` or `{:error, :quota_exceeded}`.
  """
  @spec check_quota(String.t(), String.t(), integer()) :: :ok | {:error, :quota_exceeded}
  def check_quota(owner_id, role_id, file_size) do
    %{used: used, limit: limit} = get_usage(owner_id, role_id)

    if used + file_size <= limit do
      :ok
    else
      {:error, :quota_exceeded}
    end
  end

  @doc """
  Generates a presigned URL for direct upload to MinIO.
  """
  @spec generate_upload_url(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def generate_upload_url(bucket, key) do
    config = ExAws.Config.new(:s3)
    ExAws.S3.presigned_url(config, :put, bucket, key, expires_in: 900)
  end

  @doc """
  Generates a presigned URL for downloading a file directly from MinIO.
  """
  @spec generate_download_url(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def generate_download_url(bucket, key) do
    config = ExAws.Config.new(:s3)
    ExAws.S3.presigned_url(config, :get, bucket, key, expires_in: 900)
  end

  @doc """
  Persists file metadata into the database after a successful S3 upload.
  """
  @spec create_file(map()) :: {:ok, File.t()} | {:error, Ecto.Changeset.t()}
  def create_file(attrs) do
    %File{}
    |> File.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Deletes a file from the database and physically removes it from S3.
  """
  @spec delete_file(File.t()) :: {:ok, File.t()} | {:error, term()}
  def delete_file(%File{} = file) do
    case ExAws.S3.delete_object(file.bucket, file.key) |> ExAws.request() do
      {:ok, _} ->
        Repo.delete(file)

      error ->
        error
    end
  end

  @doc """
  Finds a file by its S3 key and deletes it from both S3 and the database.
  """
  @spec delete_file_by_key(String.t()) :: {:ok, File.t() | nil} | {:error, term()}
  def delete_file_by_key(key) do
    case Repo.get_by(File, key: key) do
      %File{} = file -> delete_file(file)
      nil -> {:ok, nil}
    end
  end
end
