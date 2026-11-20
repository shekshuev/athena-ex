defmodule Athena.Media.EndpointTest do
  use Athena.DataCase, async: false

  import Athena.Factory

  alias Athena.Media

  setup do
    config = Application.get_env(:athena, Media)
    on_exit(fn -> Application.put_env(:athena, Media, config) end)
    :ok
  end

  test "public HTTPS signing leaves internal HTTP storage requests unchanged" do
    internal = ExAws.Config.new(:s3)
    assert internal.scheme == "http://"

    Application.put_env(
      :athena,
      Media,
      Keyword.merge(Application.get_env(:athena, Media),
        public_host: "storage.example.test",
        public_port: "443",
        public_scheme: "https://"
      )
    )

    for generate <- [&Media.generate_upload_url/2, &Media.generate_download_url/2] do
      assert {:ok, url} = generate.("athena", "path/archive.7z")
      uri = URI.parse(url)
      assert uri.scheme == "https"
      assert uri.host == "storage.example.test"
      assert uri.port == 443
      assert uri.path == "/athena/path/archive.7z"
      assert URI.decode_query(uri.query)["X-Amz-Signature"]
    end

    assert ExAws.Config.new(:s3) == internal

    file = insert(:media_file)
    on_exit(fn -> ExAws.S3.delete_object(file.bucket, file.key) |> ExAws.request() end)

    assert {:ok, _} = ExAws.S3.put_object(file.bucket, file.key, "test file") |> ExAws.request()
    assert {:ok, _} = Media.delete_file(file)
    assert Repo.get(Media.File, file.id) == nil

    assert {:error, {:http_error, 404, _}} =
             ExAws.S3.head_object(file.bucket, file.key) |> ExAws.request()
  end

  test "existing deployments can inherit the internal endpoint scheme" do
    Application.put_env(:athena, Media, public_host: "storage.example.test", public_port: "9000")
    assert {:ok, url} = Media.generate_upload_url("athena", "archive.7z")
    assert URI.parse(url).scheme == "http"
    assert URI.parse(url).port == 9000
  end
end
