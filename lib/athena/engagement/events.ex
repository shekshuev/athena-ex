defmodule Athena.Engagement.Events do
  @moduledoc """
  Internal business logic for recording and reading raw engagement events.

  Writes are batched and untrusted-but-server-normalized (the client reports
  its own event stream; `account_id`/`session_id`/`section_id` are always
  attached server-side by the caller, never taken from the payload as-is).
  """

  import Ecto.Query
  alias Athena.Engagement.Event
  alias Athena.Repo

  @doc """
  Inserts a batch of raw events for one account/session in a single
  `insert_all`. Events are trusted server telemetry (attached by the Player,
  not user-editable business data), so no per-row changeset validation runs
  on the hot path.
  """
  @spec record_events(binary(), binary() | nil, binary(), [map()]) ::
          {:ok, {non_neg_integer(), [map()]}} | {:error, :empty}
  def record_events(_account_id, _cohort_id, _session_id, []), do: {:error, :empty}

  def record_events(account_id, cohort_id, session_id, events) when is_list(events) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      Enum.map(events, fn event ->
        %{
          id: Ecto.UUID.generate(),
          account_id: account_id,
          cohort_id: cohort_id,
          session_id: session_id,
          block_id: Map.fetch!(event, :block_id),
          section_id: Map.fetch!(event, :section_id),
          event_type: Map.fetch!(event, :event_type),
          payload: Map.get(event, :payload, %{}),
          occurred_at: Map.get(event, :occurred_at, now),
          inserted_at: now
        }
      end)

    {count, nil} = Repo.insert_all(Event, rows)
    {:ok, {count, rows}}
  end

  @doc """
  Returns the ordered raw event timeline for a single student session
  (used by the "live replay" view).
  """
  @spec get_session_timeline(binary(), binary()) :: [Event.t()]
  def get_session_timeline(account_id, session_id) do
    Event
    |> where([e], e.account_id == ^account_id and e.session_id == ^session_id)
    |> order_by([e], asc: e.occurred_at)
    |> Repo.all()
  end

  @doc """
  Raw events for a scope (block ids, optionally a cohort, optionally a
  `since` lower bound on `occurred_at`) - used both for the bootstrap query
  inside `Athena.Engagement.BlockStats` and by `Athena.Engagement.Metrics`.

  `since` exists for `Metrics.student_radar/3`: indices need to reflect
  *recent* behavior (e.g. the last 7 days), not a lifetime total, so a
  student's numbers can actually be seen to change after a teacher steps
  in - a permanently cumulative score would never show that. Omitting it
  (the default) preserves the exact prior behavior for every existing
  caller.
  """
  @spec list_events_for_scope([binary()], binary() | nil, DateTime.t() | nil) :: [Event.t()]
  def list_events_for_scope(block_ids, cohort_id \\ nil, since \\ nil) do
    Event
    |> where([e], e.block_id in ^block_ids)
    |> maybe_filter_cohort(cohort_id)
    |> maybe_filter_since(since)
    |> Repo.all()
  end

  defp maybe_filter_cohort(query, nil), do: query
  defp maybe_filter_cohort(query, cohort_id), do: where(query, [e], e.cohort_id == ^cohort_id)

  defp maybe_filter_since(query, nil), do: query
  defp maybe_filter_since(query, since), do: where(query, [e], e.occurred_at >= ^since)

  @doc """
  Pairs `viewport_enter`/`viewport_exit` events (already fetched, e.g. via
  `list_events_for_scope/2`) into per-session dwell seconds, with any
  overlapping `idle_start`/`idle_end` windows subtracted first. Shared by
  `Athena.Engagement.BlockStats` (which needs it for a single bootstrap
  query) and `Athena.Engagement.Metrics` (which needs the exact same
  definition of "dwell" for its aggregate metrics) - dwell time is derived
  exactly once, in one place.

  Idle subtraction matters because a tab can stay focused and in view (no
  `tab_hidden`) while the student has simply stepped away - without this, a
  15-minute bathroom break would be indistinguishable from 15 minutes of
  genuine difficulty (`:slow_dwell`), which would make the whole signal
  worthless to a teacher acting on it. Both `events` callers already pass in
  events pre-filtered to one block, so idle windows here are implicitly
  scoped to that same block - no extra filtering needed.
  """
  @spec pair_viewport_dwells([Event.t()]) :: [
          {session_id :: binary(), account_id :: binary(), dwell_seconds :: non_neg_integer()}
        ]
  def pair_viewport_dwells(events) do
    events
    |> Enum.group_by(& &1.session_id)
    |> Enum.flat_map(fn {session_id, session_events} ->
      sorted = Enum.sort_by(session_events, & &1.occurred_at, DateTime)
      account_id = sorted |> List.first() |> Map.get(:account_id)
      idle_windows = windows_for(sorted, :idle_start, :idle_end)

      sorted
      |> windows_for(:viewport_enter, :viewport_exit)
      |> Enum.map(fn {enter_at, exit_at} ->
        raw_seconds = DateTime.diff(exit_at, enter_at, :second)
        idle_seconds = idle_overlap_seconds(idle_windows, enter_at, exit_at)
        {session_id, account_id, max(raw_seconds - idle_seconds, 0)}
      end)
    end)
  end

  @doc """
  Raw (not idle-adjusted) `viewport_enter`/`viewport_exit` window lengths, in
  seconds, across all sessions - the denominator `Athena.Engagement.Metrics`
  needs for `offtask_ratio` (how much of the *wall-clock* time nominally
  spent on a block was actually spent tabbed away). Deliberately not
  idle-adjusted like `pair_viewport_dwells/1`: idle time (tab focused, no
  activity) and off-task time (tab not focused at all) are two different
  categories of "not engaged" - subtracting one while measuring the other
  would double-count in a confusing way.
  """
  @spec raw_viewport_window_seconds([Event.t()]) :: [non_neg_integer()]
  def raw_viewport_window_seconds(events) do
    events
    |> Enum.group_by(& &1.session_id)
    |> Enum.flat_map(fn {_session_id, session_events} ->
      session_events
      |> Enum.sort_by(& &1.occurred_at, DateTime)
      |> windows_for(:viewport_enter, :viewport_exit)
      |> Enum.map(fn {enter_at, exit_at} -> max(DateTime.diff(exit_at, enter_at, :second), 0) end)
    end)
  end

  # Generic "pair a start-type event with the very next end-type event"
  # extractor - used for both viewport enter/exit and idle start/end, since
  # both are the same shape (an unlabelled interval bounded by two event
  # types in one session's chronological stream).
  defp windows_for(sorted_events, start_type, end_type) do
    sorted_events
    |> Enum.filter(&(&1.event_type in [start_type, end_type]))
    |> pair_windows(start_type, end_type, [])
  end

  defp pair_windows(
         [
           %{event_type: start_type, occurred_at: start_at}
           | [%{event_type: end_type, occurred_at: end_at} | rest]
         ],
         start_type,
         end_type,
         acc
       ) do
    pair_windows(rest, start_type, end_type, [{start_at, end_at} | acc])
  end

  defp pair_windows([_ | rest], start_type, end_type, acc),
    do: pair_windows(rest, start_type, end_type, acc)

  defp pair_windows([], _start_type, _end_type, acc), do: Enum.reverse(acc)

  # Sum of how much each idle window overlaps the [window_start, window_end]
  # dwell interval, clipping at the interval's own edges - an idle period
  # that started before the block was entered, or that hadn't ended by the
  # time the student left, still only counts for the part that actually
  # falls inside this particular dwell window.
  defp idle_overlap_seconds(idle_windows, window_start, window_end) do
    idle_windows
    |> Enum.map(fn {idle_start, idle_end} ->
      overlap_start = later_of(idle_start, window_start)
      overlap_end = earlier_of(idle_end, window_end)
      max(DateTime.diff(overlap_end, overlap_start, :second), 0)
    end)
    |> Enum.sum()
  end

  defp later_of(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)
  defp earlier_of(a, b), do: if(DateTime.compare(a, b) == :lt, do: a, else: b)
end
