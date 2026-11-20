defmodule Athena.Media.Config do
  @moduledoc """
  Centralized configuration for media uploads across the platform.
  """

  use Gettext, backend: AthenaWeb.Gettext

  @mb 1024 * 1024
  @gb 1024 * 1024 * 1024

  @file_extensions ~w(.pdf .doc .docx .xls .xlsx .ppt .pptx .txt .csv .rtf
                      .zip .rar .7z .tar .gz .mp3 .wav .flac
                      .jpg .jpeg .png .gif .webp .svg .bmp .tiff
                      .mp4 .mov .webm .avi .mkv .py .cpp .c .h .js .ts .json)

  def upload_settings("video") do
    %{
      accept: ~w(.mp4 .mov .webm .avi .mkv),
      max_entries: 1,
      max_size: 2 * @gb,
      description: gettext(".MP4, .MOV, .WEBM, .AVI, .MKV (Max 2GB)")
    }
  end

  def upload_settings(type) when type in ["attachment", "file_assignment", "personal"] do
    %{
      accept: @file_extensions,
      max_entries: if(type == "attachment", do: 10, else: 20),
      max_size: 2 * @gb,
      description:
        gettext("Documents, code, archives (including 7z), images, audio, video (Max 2GB each)")
    }
  end

  def upload_settings("avatar") do
    %{
      accept: ~w(.jpg .jpeg .png .gif .webp),
      max_entries: 1,
      max_size: 5 * @mb,
      description: gettext(".JPG, .PNG, .GIF, .WEBP (Max 5MB)")
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
