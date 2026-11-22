defmodule Athena.Media.Delivery do
  @moduledoc "Server-owned content types and download disposition for untrusted objects."

  alias Athena.Media.Config

  @inline %{
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".png" => "image/png",
    ".gif" => "image/gif",
    ".webp" => "image/webp",
    ".bmp" => "image/bmp",
    ".tiff" => "image/tiff",
    ".mp3" => "audio/mpeg",
    ".wav" => "audio/wav",
    ".flac" => "audio/flac",
    ".mp4" => "video/mp4",
    ".webm" => "video/webm",
    ".mov" => "video/quicktime",
    ".avi" => "video/x-msvideo",
    ".mkv" => "video/x-matroska"
  }

  def content_type(key), do: Map.get(@inline, extension(key), "application/octet-stream")

  def allowed_upload?(key) do
    extension(key) in Config.upload_settings("attachment").accept
  end

  def download_params(key) do
    type = content_type(key)
    disposition = if Map.has_key?(@inline, extension(key)), do: "inline", else: "attachment"
    name = key |> Path.basename() |> String.replace(~r/[\x00-\x1f\x7f"\\]/, "_")

    [
      {"response-content-type", type},
      {"response-content-disposition",
       "#{disposition}; filename*=UTF-8''#{URI.encode(name, &URI.char_unreserved?/1)}"}
    ]
  end

  defp extension(key), do: key |> Path.extname() |> String.downcase()
end
