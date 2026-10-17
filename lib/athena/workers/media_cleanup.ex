defmodule Athena.Workers.MediaCleanup do
  @moduledoc """
  Oban worker that finds and deletes orphaned media files.
  Runs periodically via Oban.Plugins.Cron.

  Checks Block.content, LibraryBlock.content and Submission.content for file
  references to ensure files used in file assignments and in the question
  bank are not prematurely deleted.

  File URLs are stored as strings inside the JSON content (e.g.
  `"file_urls": ["/media/courses/1/file.pdf"]`), so a file counts as
  referenced when its key appears anywhere in a block's or library block's
  content text, or as `/media/<key>` in a submission's content.

  Each table is read once, in id-ordered batches, and every content text is
  searched for all candidate keys at once (`:binary.matches/2`), so the cost
  is one pass over the content rather than files × rows jsonb-to-text casts.

  Files younger than 24 hours are never candidates: an upload is only
  referenced once the block or submission holding it is saved.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger
  import Ecto.Query
  alias Athena.{Repo, Media}
  alias Athena.Media.File
  alias Athena.Content.Block
  alias Athena.Content.LibraryBlock
  alias Athena.Learning.Submission

  @min_age_hours 24
  @batch_size 500

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)

  @impl Oban.Worker
  def perform(_job) do
    Logger.info("[Media.Cleanup] Starting garbage collection for orphaned files...")

    cutoff = DateTime.add(DateTime.utc_now(:second), -@min_age_hours, :hour)

    from(f in File,
      where: f.context in [:course_material, :submission] and f.inserted_at < ^cutoff
    )
    |> Repo.all()
    |> orphaned_files()
    |> process_orphaned_files()
  end

  @doc false
  defp orphaned_files([]), do: []

  defp orphaned_files(files) do
    keys = files |> Enum.map(& &1.key) |> Enum.uniq()
    total = length(keys)

    referenced =
      MapSet.new()
      |> collect_references(Block, keys, "", total)
      |> collect_references(LibraryBlock, keys, "", total)
      |> collect_references(Submission, keys, "/media/", total)

    Enum.reject(files, &MapSet.member?(referenced, &1.key))
  end

  # Adds to `found` every key (searched as `prefix <> key`) that occurs in
  # the content of any row of `schema`. Stops early once all keys are found.
  # Matches don't overlap: where one key is a prefix of another at the same
  # spot, only the longer one counts (keys carry unique file names, so in
  # practice the shorter one isn't referenced there anyway).
  defp collect_references(found, schema, keys, prefix, total) do
    if MapSet.size(found) == total do
      found
    else
      pattern = keys |> Enum.map(&(prefix <> &1)) |> :binary.compile_pattern()
      scan(schema, nil, pattern, byte_size(prefix), total, found)
    end
  end

  defp scan(schema, after_id, pattern, prefix_size, total, found) do
    rows =
      schema
      |> after_id(after_id)
      |> where([r], not is_nil(r.content))
      |> order_by([r], asc: r.id)
      |> limit(@batch_size)
      |> select([r], {r.id, fragment("?::text", r.content)})
      |> Repo.all()

    found =
      Enum.reduce(rows, found, fn {_id, text}, acc ->
        text
        |> :binary.matches(pattern)
        |> Enum.reduce(acc, fn {pos, len}, acc ->
          MapSet.put(acc, binary_part(text, pos + prefix_size, len - prefix_size))
        end)
      end)

    cond do
      MapSet.size(found) == total -> found
      length(rows) < @batch_size -> found
      true -> scan(schema, rows |> List.last() |> elem(0), pattern, prefix_size, total, found)
    end
  end

  defp after_id(query, nil), do: query
  defp after_id(query, id), do: where(query, [r], r.id > ^id)

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
