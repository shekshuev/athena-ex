defmodule Athena.Workers.MediaCleanup do
  @moduledoc """
  Oban worker that finds and deletes orphaned media files.
  Runs periodically via Oban.Plugins.Cron.

  Checks both Block.content and Submission.content for file references
  to ensure files used in file assignments are not prematurely deleted.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger
  import Ecto.Query
  alias Athena.{Repo, Media}
  alias Athena.Media.File
  alias Athena.Content.Block
  alias Athena.Learning.Submission

  @impl Oban.Worker
  def perform(_job) do
    Logger.info("[Media.Cleanup] Starting garbage collection for orphaned files...")

    # Find files that are NOT referenced in any Block.content OR Submission.content.
    # File URLs are stored as strings in JSON content (e.g., "file_urls": ["https://s3/file.pdf"]),
    # so we search for the file key within the JSON text representation.
    query =
      from f in File,
        as: :file,
        where: f.context in [:course_material, :submission],
        where:
          not exists(
            from b in Block,
              where: fragment("?::text LIKE '%' || ? || '%'", b.content, parent_as(:file).key)
          ) and
            not exists(
              from s in Submission,
                where:
                  fragment(
                    "?::text LIKE '%' || '/media/' || ? || '%'",
                    s.content,
                    parent_as(:file).key
                  )
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
