defmodule Athena.Tasks.BackfillSearchText do
  @moduledoc """
  A bounded search-text backfill for a running web node (including IEx).

  Requires the application's Repo and Oban to be started.
  They schedule work; returning successfully does not mean it has finished.
  """

  @behaviour Athena.Tasks

  import Ecto.Query
  require Logger

  alias Athena.Content.{Block, SearchIndex}
  alias Athena.Content.Workers.IndexBlockSearch
  alias Athena.Repo

  @doc """
  Schedules missing/dirty search texts in UUID order, without reading content.

  Options:

    * `:batch_size`: IDs fetched per query, 1..1000 (default 100).
    * `:limit`: maximum blocks examined per invocation (default 1000).
    * `:max_pending_jobs`: stop at this observed indexing backlog (default 1000).
    * `:after_id`: resume strictly after this UUID (default nil).
    * `:rebuild`: also invalidate current texts (default false).

  Returns `{:ok, summary}` with `:complete`, `:limit_reached` or `:queue_full`
  status, or `{:error, summary}` on a scheduling failure. The last successfully
  examined ID is `summary.after_id`; a failed block is not skipped on resume.
  Progress, including the cursor, is logged after each batch and on exit.

  The backlog limit is conservative within an invocation, not a global
  reservation: concurrent editors or other manual invocations can add jobs.
  Worker concurrency remains controlled by the existing Oban queue.

  A fresh default invocation starts from the beginning and catches UUIDs
  inserted before a previous cursor. An explicit rebuild starts a new rebuild;
  to continue one, pass both `rebuild: true` and the last logged `after_id`.
  """
  @impl true
  def run(opts \\ []) do
    opts = validate_options!(opts)

    summary = %{
      after_id: opts[:after_id],
      scanned: 0,
      enqueued: 0,
      skipped: 0,
      pending: 0,
      current: 0,
      deleted: 0,
      errors: 0,
      batches: 0
    }

    scan(opts, summary)
  end

  @doc "Returns read-only counts of missing/dirty texts and indexing jobs by state."
  def status do
    counts =
      Repo.one(
        from b in Block,
          select: %{
            unindexed: filter(count(b.id), is_nil(b.search_text)),
            dirty: filter(count(b.id), not is_nil(b.search_due_at)),
            needs_indexing:
              filter(count(b.id), is_nil(b.search_text) or not is_nil(b.search_due_at))
          }
      )

    jobs =
      Repo.all(
        from j in Oban.Job,
          where: j.worker == ^Oban.Worker.to_string(IndexBlockSearch),
          group_by: j.state,
          select: {j.state, count(j.id)}
      )

    Map.put(counts, :jobs, Map.new(jobs))
  end

  defp scan(opts, summary) do
    query = candidate_query(opts, summary.after_id)
    remaining = opts[:limit] - summary.scanned

    if remaining == 0 do
      status = if Repo.exists?(query), do: :limit_reached, else: :complete
      finish(summary, status)
    else
      ids =
        Repo.all(
          from b in query,
            order_by: b.id,
            limit: ^min(opts[:batch_size], remaining),
            select: b.id
        )

      case ids do
        [] -> finish(summary, :complete)
        ids -> process_batch(ids, opts, summary)
      end
    end
  end

  defp process_batch(ids, opts, summary) do
    room = max(opts[:max_pending_jobs] - SearchIndex.pending_jobs_count(), 0)
    summary = %{summary | batches: summary.batches + 1}

    result =
      Enum.reduce_while(ids, {summary, room}, fn id, state ->
        process_block(id, state, opts[:rebuild])
      end)

    case result do
      {:queue_full, summary} ->
        finish(summary, :queue_full)

      {:error, summary} ->
        finish(summary, :error)

      {summary, _room} ->
        log_progress(summary)
        scan(opts, summary)
    end
  end

  defp process_block(_id, {summary, 0}, _rebuild?),
    do: {:halt, {:queue_full, summary}}

  defp process_block(id, {summary, room}, rebuild?) do
    case SearchIndex.ensure_scheduled(id, rebuild?) do
      {:ok, outcome} ->
        summary = record(summary, id, outcome)
        room = if outcome == :enqueued, do: room - 1, else: room
        {:cont, {summary, room}}

      {:error, reason} ->
        summary = %{summary | scanned: summary.scanned + 1, errors: summary.errors + 1}
        {:halt, {:error, Map.put(summary, :error, %{block_id: id, reason: reason})}}
    end
  end

  defp record(summary, id, outcome) do
    summary = %{summary | after_id: id, scanned: summary.scanned + 1}

    if outcome == :enqueued do
      %{summary | enqueued: summary.enqueued + 1}
    else
      summary |> Map.update!(:skipped, &(&1 + 1)) |> Map.update!(outcome, &(&1 + 1))
    end
  end

  defp candidate_query(opts, after_id) do
    query =
      if opts[:rebuild] do
        Block
      else
        from b in Block, where: is_nil(b.search_text) or not is_nil(b.search_due_at)
      end

    if after_id, do: from(b in query, where: b.id > ^after_id), else: query
  end

  defp finish(summary, status) do
    summary = Map.put(summary, :status, status)
    log_progress(summary)
    if status == :error, do: {:error, summary}, else: {:ok, summary}
  end

  defp log_progress(summary),
    do: Logger.info("[Search.Backfill] planning only: #{inspect(summary)}")

  defp validate_options!(opts) do
    opts =
      Keyword.validate!(opts,
        batch_size: 100,
        limit: 1000,
        max_pending_jobs: 1000,
        after_id: nil,
        rebuild: false
      )

    Enum.each([:batch_size, :limit, :max_pending_jobs], &validate_positive_integer!(opts, &1))

    if opts[:batch_size] > 1000, do: raise(ArgumentError, "batch_size must be at most 1000")
    unless is_boolean(opts[:rebuild]), do: raise(ArgumentError, "rebuild must be a boolean")

    Keyword.update!(opts, :after_id, &normalize_cursor!/1)
  end

  defp validate_positive_integer!(opts, key) do
    value = opts[key]

    unless is_integer(value) and value > 0,
      do: raise(ArgumentError, "#{key} must be a positive integer")
  end

  defp normalize_cursor!(nil), do: nil

  defp normalize_cursor!(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> id
      :error -> raise ArgumentError, "after_id must be a UUID"
    end
  end
end
