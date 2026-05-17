defmodule Athena.Media.Config do
  @moduledoc """
  Centralized configuration for media uploads across the platform.
  """

  use Gettext, backend: AthenaWeb.Gettext

  @mb 1024 * 1024
  @gb 1024 * 1024 * 1024

  def upload_settings("video") do
    %{
      accept: ~w(.mp4 .mov .webm .avi .mkv),
      max_entries: 1,
      max_size: 1 * @gb,
      description: gettext(".MP4, .MOV, .WEBM, .AVI, .MKV (Max 1GB)")
    }
  end

  def upload_settings("attachment") do
    %{
      accept:
        ~w(.pdf .doc .docx .xls .xlsx .ppt .pptx .txt .csv .rtf .zip .rar .7z .tar .gz .mp3 .wav .flac),
      max_entries: 10,
      max_size: 2 * @gb,
      description: gettext("Docs, PDFs, Archives, Audio (Max 2GB, 10 files)")
    }
  end

  def upload_settings(_) do
    %{
      accept: ~w(.jpg .jpeg .png .gif .webp .svg .bmp .tiff),
      max_entries: 1,
      max_size: 25 * @mb,
      description: gettext("Images (Max 25MB)")
    }
  end

  @doc "Returns a comma-separated string of extensions (e.g. '.JPG, .PNG') for a given type"
  def format_extensions(type) do
    type
    |> upload_settings()
    |> Map.get(:accept)
    |> Enum.map_join(", ", fn "." <> ext -> String.upcase(ext) end)
  end
end
