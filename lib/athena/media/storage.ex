defmodule Athena.Media.Storage do
  @moduledoc "Explicit, idempotent S3 bucket provisioning and privacy enforcement."

  alias Athena.Media

  def buckets do
    config = Application.get_env(:athena, Media, [])
    config[:buckets] || [config[:bucket] || "athena"]
  end

  def setup! do
    Enum.each(buckets(), fn bucket ->
      case ExAws.S3.head_bucket(bucket) |> ExAws.request() do
        {:ok, _} -> :ok
        {:error, {:http_error, 404, _}} -> ExAws.S3.put_bucket(bucket, "") |> ExAws.request!()
        error -> raise "Cannot inspect bucket #{bucket}: #{inspect(error)}"
      end

      privatize!(bucket)
    end)
  end

  def inspect_bucket!(bucket) do
    ExAws.S3.head_bucket(bucket) |> ExAws.request!()

    case ExAws.S3.get_bucket_policy(bucket) |> ExAws.request() do
      {:ok, %{body: body}} -> %{bucket: bucket, policy: body}
      {:error, {:http_error, 404, _}} -> %{bucket: bucket, policy: nil}
      error -> raise "Cannot read bucket policy for #{bucket}: #{inspect(error)}"
    end
  end

  def privatize!(bucket) do
    ExAws.S3.delete_bucket_policy(bucket) |> ExAws.request!()
    %{policy: nil} = inspect_bucket!(bucket)
    :ok
  end

  @doc "Dry-run by default. Applying requires a policy backup directory."
  def harden!(opts \\ []) do
    selected = Keyword.get(opts, :buckets, buckets())
    apply? = Keyword.get(opts, :apply, false)
    snapshots = Enum.map(selected, &inspect_bucket!/1)

    if apply? do
      directory = Path.join(Keyword.fetch!(opts, :backup_dir), Ecto.UUID.generate())
      File.mkdir_p!(directory)
      # Back up every selected policy before touching any bucket. Exclusive
      # creation prevents a second run from overwriting the original backup.
      Enum.each(snapshots, fn snapshot ->
        name = Base.url_encode64(snapshot.bucket, padding: false) <> ".json"
        path = Path.join(directory, name)
        File.write!(path, Jason.encode!(snapshot), [:exclusive])
        File.chmod!(path, 0o600)
      end)

      Enum.each(selected, &privatize!/1)
    end

    Enum.map(snapshots, fn snapshot ->
      %{bucket: snapshot.bucket, had_policy: snapshot.policy != nil, applied: apply?}
    end)
  end

  @doc "Verifies signed GET/PUT and denies anonymous read/list/write/delete on an owned probe."
  def verify!(bucket) do
    key = "submissions/_privacy_check/#{Ecto.UUID.generate()}.txt"
    marker = "athena-private-storage-check"
    {:ok, put_url} = Media.generate_upload_url(bucket, key)
    {:ok, get_url} = Media.generate_download_url(bucket, key)
    unsigned = %{URI.parse(get_url) | query: nil} |> URI.to_string()

    bucket_url =
      %{URI.parse(unsigned) | path: "/#{bucket}", query: "list-type=2"} |> URI.to_string()

    try do
      %{status: 200} =
        request!(:put, put_url,
          body: marker,
          headers: [{"content-type", Media.upload_content_type(key)}]
        )

      %{status: 200, body: ^marker} = request!(:get, get_url)

      for {method, url} <- [get: unsigned, get: bucket_url, put: unsigned, delete: unsigned] do
        response = request!(method, url, body: if(method == :put, do: marker, else: ""))

        unless response.status == 403 do
          raise "Anonymous #{method} unexpectedly returned #{response.status} for bucket #{bucket}"
        end
      end

      :ok
    after
      ExAws.S3.delete_object(bucket, key) |> ExAws.request!()
    end
  end

  defp request!(method, url, opts \\ []) do
    Req.request!(
      Keyword.merge(
        [
          method: method,
          url: url,
          retry: false,
          redirect: false,
          decode_body: false,
          receive_timeout: 15_000
        ],
        opts
      )
    )
  end
end
