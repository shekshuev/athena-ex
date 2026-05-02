defmodule Athena.Workers.MediaCleanup do
  @moduledoc """
  Oban worker that finds and deletes orphaned media files.
  Runs periodically via Oban.Plugins.Cron.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger
  import Ecto.Query
  alias Athena.{Repo, Media}
  alias Athena.Media.File
  alias Athena.Content.Block

  @impl Oban.Worker
  def perform(_job) do
    Logger.info("[Media.Cleanup] Starting garbage collection for orphaned files via Oban...")

    query =
      from f in File,
        as: :file,
        where: f.context == :course_material,
        where:
          not exists(
            from b in Block,
              where: fragment("?::text LIKE '%' || ? || '%'", b.content, parent_as(:file).key)
          )

    query
    |> Repo.all()
    |> process_orphaned_files()
  end

  @doc false
  defp process_orphaned_files([]) do
    Logger.info("[Media.Cleanup] No orphaned files found. Everything is clean!")
    :ok
  end

  defp process_orphaned_files(orphaned_files) do
    Logger.info("[Media.Cleanup] Found #{length(orphaned_files)} orphaned files. Deleting...")

    Enum.each(orphaned_files, &delete_orphaned_file/1)

    Logger.info("[Media.Cleanup] Cleanup finished successfully.")
    :ok
  end

  defp delete_orphaned_file(file) do
    Logger.info(" -> Deleting #{file.original_name} (#{file.key})")

    case Media.delete_file(file) do
      {:ok, _} -> :ok
      {:error, err} -> Logger.error("Failed to delete #{file.key}: #{inspect(err)}")
    end
  end
end
