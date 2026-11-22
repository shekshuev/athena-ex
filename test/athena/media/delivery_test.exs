defmodule Athena.Media.DeliveryTest do
  use Athena.DataCase, async: true
  alias Athena.Media

  test "upload signature fixes the server-selected content type" do
    assert {:ok, url} = Media.generate_upload_url("bucket", "path/photo.png")
    query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert query["X-Amz-SignedHeaders"] == "content-type;host"
    assert Media.upload_content_type("photo.png") == "image/png"
    assert Media.upload_content_type("source.js") == "application/octet-stream"
    assert {:error, :unsupported_file_type} = Media.generate_upload_url("bucket", "attack.html")
  end

  test "active formats and ordinary documents always download as inert attachments" do
    for name <- [
          "attack.html",
          "attack.svg",
          "source.js",
          "document.pdf",
          "archive.7z",
          "attack.xhtml"
        ] do
      assert {:ok, url} = Media.generate_download_url("bucket", name)
      query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      assert query["response-content-type"] == "application/octet-stream"
      assert String.starts_with?(query["response-content-disposition"], "attachment;")
    end
  end

  test "raster images and audio/video retain inline rendering" do
    for {name, type} <- [
          {"picture.png", "image/png"},
          {"movie.mp4", "video/mp4"},
          {"track.mp3", "audio/mpeg"}
        ] do
      assert {:ok, url} = Media.generate_download_url("bucket", name)
      query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      assert query["response-content-type"] == type
      assert String.starts_with?(query["response-content-disposition"], "inline;")
    end
  end

  test "signed uploads and safe downloads work against the real private storage" do
    bucket = Application.fetch_env!(:athena, Media)[:bucket]
    key = "delivery-tests/#{Ecto.UUID.generate()}.svg"
    on_exit(fn -> ExAws.S3.delete_object(bucket, key) |> ExAws.request() end)
    assert {:ok, put_url} = Media.generate_upload_url(bucket, key)
    body = "<svg xmlns=\"http://www.w3.org/2000/svg\"><script>alert(1)</script></svg>"

    assert %{status: 403} =
             Req.put!(put_url,
               body: body,
               headers: [{"content-type", "image/svg+xml"}],
               retry: false
             )

    assert %{status: 200} =
             Req.put!(put_url,
               body: body,
               headers: [{"content-type", Media.upload_content_type(key)}],
               retry: false
             )

    assert {:ok, get_url} = Media.generate_download_url(bucket, key)
    response = Req.get!(get_url, decode_body: false, retry: false)
    assert response.status == 200
    assert response.body == body
    assert Req.Response.get_header(response, "content-type") == ["application/octet-stream"]
    assert [disposition] = Req.Response.get_header(response, "content-disposition")
    assert String.starts_with?(disposition, "attachment;")

    assert %{status: 403} =
             Req.get!(%{URI.parse(get_url) | query: nil} |> URI.to_string(), retry: false)
  end
end
