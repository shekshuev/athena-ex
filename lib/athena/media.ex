defmodule Athena.Media do
  @moduledoc """
  Business logic for Media and S3 integrations.
  """

  import Ecto.Query
  alias Athena.Repo
  alias Athena.Media.{File, Quota}
  alias Athena.Identity.{Acl, Account, Role}

  @default_quota_bytes 100 * 1024 * 1024

  @kb 1024
  @mb 1024 * 1024
  @gb 1024 * 1024 * 1024

  @doc """
  Retrieves a paginated list of files.
  """
  @spec list_files(map()) :: {:ok, {[File.t()], Flop.Meta.t()}} | {:error, Flop.Meta.t()}
  def list_files(params \\ %{}) do
    Flop.validate_and_run(File, params, for: File)
  end

  @doc """
  Retrieves a paginated list of files scoped by the given user's `files.read`
  permission and policies (e.g. `own_only`).
  """
  @spec list_files(map(), map(), keyword()) ::
          {:ok, {[File.t()], Flop.Meta.t()}} | {:error, Flop.Meta.t()}
  def list_files(user, params, _opts \\ []) do
    from(f in File)
    |> Acl.scope_query(user, "files.read")
    |> Flop.validate_and_run(params, for: File)
  end

  @doc """
  Retrieves a paginated list of a user's own personal files.
  """
  @spec list_personal_files(map(), map()) ::
          {:ok, {[File.t()], Flop.Meta.t()}} | {:error, Flop.Meta.t()}
  def list_personal_files(user, params \\ %{}) do
    File
    |> where([f], f.owner_id == ^user.id and f.context == :personal)
    |> Flop.validate_and_run(params, for: File)
  end

  @doc """
  Formats a byte count as a human-readable string (e.g. "12.4 MB").
  """
  @spec format_bytes(integer()) :: String.t()
  def format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes >= @gb -> "#{Float.round(bytes / @gb, 1)} GB"
      bytes >= @mb -> "#{Float.round(bytes / @mb, 1)} MB"
      bytes >= @kb -> "#{Float.round(bytes / @kb, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  @doc """
  Lists all roles with their storage quota limit and current usage,
  for the admin storage-quota management panel.
  """
  @spec list_role_quotas(map()) :: [%{role: Role.t(), used: integer(), limit: integer()}]
  def list_role_quotas(user) do
    if Acl.can?(user, "files.read") do
      usage_subquery =
        from f in File,
          join: a in Account,
          on: a.id == f.owner_id,
          where: f.context == :personal,
          group_by: a.role_id,
          select: %{role_id: a.role_id, used: sum(f.size)}

      from(r in Role,
        left_join: u in subquery(usage_subquery),
        on: u.role_id == r.id,
        left_join: q in Quota,
        on: q.role_id == r.id,
        order_by: r.name,
        select: %{
          role: r,
          used: coalesce(u.used, 0),
          limit: coalesce(q.limit_bytes, ^@default_quota_bytes)
        }
      )
      |> Repo.all()
      |> Enum.map(&Map.update!(&1, :used, fn used -> to_integer(used) end))
    else
      []
    end
  end

  defp to_integer(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_integer(int) when is_integer(int), do: int

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
    public_config = get_public_config()

    ExAws.S3.presigned_url(public_config, :put, bucket, key, expires_in: 900)
  end

  @doc """
  Generates a presigned URL for downloading a file directly from MinIO.
  """
  @spec generate_download_url(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def generate_download_url(bucket, key) do
    public_config = get_public_config()

    ExAws.S3.presigned_url(public_config, :get, bucket, key, expires_in: 900)
  end

  @doc false
  defp get_public_config do
    config = ExAws.Config.new(:s3)
    media_conf = Application.get_env(:athena, Athena.Media)

    host = media_conf[:public_host] || config.host

    port =
      case media_conf[:public_port] do
        nil -> config.port
        p when is_binary(p) -> String.to_integer(p)
        p -> p
      end

    %{config | host: host, port: port}
  end

  @doc """
  Retrieves a single file by id.
  """
  @spec get_file(String.t()) :: File.t() | nil
  def get_file(id), do: Repo.get(File, id)

  @doc """
  Prepares a presigned S3 upload for a user's own avatar.

  Unlike course material uploads, this is not scoped by course/section
  ownership — any authenticated account may upload its own avatar.
  """
  @spec prepare_avatar_upload(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def prepare_avatar_upload(account_id, filename) do
    bucket = Application.get_env(:athena, Athena.Media)[:bucket] || "athena"

    unique_filename = "#{Ecto.UUID.generate()}-#{filename}"
    key = "avatars/#{account_id}/#{unique_filename}"

    case generate_upload_url(bucket, key) do
      {:ok, presigned_url} ->
        meta = %{
          uploader: "S3",
          url: presigned_url,
          url_for_saved_entry: "/media/#{key}",
          bucket: bucket,
          key: key
        }

        {:ok, meta}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Prepares a presigned S3 upload for a user's own personal file.

  Any authenticated account may upload to its own personal storage space;
  the actual quota check happens separately once the file size is known
  (see `check_quota/3`).
  """
  @spec prepare_personal_upload(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def prepare_personal_upload(user, filename) do
    bucket = Application.get_env(:athena, Athena.Media)[:bucket] || "athena"

    unique_filename = "#{Ecto.UUID.generate()}-#{filename}"
    key = "personal/#{user.id}/#{unique_filename}"

    case generate_upload_url(bucket, key) do
      {:ok, presigned_url} ->
        meta = %{
          uploader: "S3",
          url: presigned_url,
          url_for_saved_entry: "/media/#{key}",
          bucket: bucket,
          key: key
        }

        {:ok, meta}

      {:error, reason} ->
        {:error, reason}
    end
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
