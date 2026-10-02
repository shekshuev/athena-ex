defmodule Athena.Engagement.ProctoringTimeline do
  @moduledoc """
  The chronological account of what a student actually did during an exam
  attempt - what the teacher reads to judge a verdict instead of trusting a
  colour. Built from the raw engagement events already recorded for the
  attempt (so it needs no extra storage) plus the silence incidents the
  `Athena.Engagement.ProctoringMonitor` stamped into the submission.

  Only events that say something about the attempt's integrity are kept,
  and an absence is shown once, at the moment it *began*: the "came back"
  events (`tab_visible`, `window_focus`, `fullscreen_exit`, `offline_period`,
  `mouse_left`) carry the duration, so each becomes a single entry placed
  `duration` earlier, rather than a hidden/visible pair.

  Absences are merged exactly the way `Athena.Engagement.ProctoringMonitor`
  merges them for the verdict (overlapping intervals are one absence): a
  single Alt-Tab usually fires both `tab_visible` and `window_focus`, and
  must read as one line, not two. A pointer excursion that happened while
  the student was already away is implied by that absence and is dropped.
  """

  import Ecto.Query

  alias Athena.Engagement.Event
  alias Athena.Repo

  @max_events 5000
  @min_mouse_away_ms 3_000
  @min_paste_chars 10
  @burst_window_seconds 5

  @instant_types [
    :printscreen_attempt,
    :copy_attempt,
    :cut_attempt,
    :right_click_attempt,
    :multi_tab_detected,
    :paste_detected,
    :bulk_insert,
    :window_geometry_changed
  ]

  @away_types [:tab_visible, :window_focus, :fullscreen_exit]
  @return_types @away_types ++ [:offline_period, :mouse_left]

  # When one merged absence was reported by several kinds of event, the entry
  # takes the most telling one: leaving the tab says more than losing focus.
  @away_priority [:tab_away, :window_away, :fullscreen_exit]

  # Instant events that, repeated within a few seconds, read as one burst.
  @burst_types [:printscreen_attempt, :copy_attempt, :cut_attempt, :right_click_attempt]

  @type entry :: %{
          offset: non_neg_integer(),
          type: atom(),
          count: pos_integer(),
          duration_ms: non_neg_integer() | nil,
          chars: non_neg_integer() | nil,
          split: boolean() | nil,
          source: String.t() | nil,
          kinds: [atom()],
          block_id: binary() | nil
        }

  @doc """
  Entries for one exam submission (any map/struct carrying `:account_id`,
  `:block_id`, `:content`, `:inserted_at`, `:updated_at` and `:status`), in
  order, each with its `offset` in seconds from the start of the attempt.
  """
  @spec build(map()) :: [entry()]
  def build(submission) do
    started_at = started_at(submission)
    block_ids = [submission.block_id | question_ids(submission)]
    events = fetch_events(submission, block_ids, started_at)

    away = away_entries(events, started_at)

    events
    |> Enum.reject(&(&1.event_type in @away_types))
    |> Enum.flat_map(&entry(&1, started_at))
    |> Enum.reject(&(&1.type == :mouse_left and covered_by_absence?(&1, away, started_at)))
    |> Kernel.++(away)
    |> Kernel.++(incident_entries(submission, started_at))
    |> Enum.sort_by(& &1.offset)
    |> collapse_bursts()
  end

  defp fetch_events(submission, block_ids, started_at) do
    Event
    |> where([e], e.account_id == ^submission.account_id and e.block_id in ^block_ids)
    |> where([e], e.event_type in ^(@instant_types ++ @return_types))
    |> where([e], e.occurred_at >= ^DateTime.add(started_at, -1, :second))
    |> order_by([e], asc: e.occurred_at)
    |> limit(^@max_events)
    |> Repo.all()
  end

  # Tab-hidden, window-blur and fullscreen-exit intervals, overlapping ones
  # merged into a single absence (same rule as the monitor: touching or
  # overlapping intervals are one).
  defp away_entries(events, started_at) do
    events
    |> Enum.filter(&(&1.event_type in @away_types))
    |> Enum.flat_map(&interval(&1, started_at))
    |> Enum.sort_by(fn {start_ms, _end_ms, _kind, _block_id} -> start_ms end)
    |> Enum.reduce([], fn
      {start_ms, end_ms, kind, block_id}, [group | rest] ->
        if start_ms <= group.end_ms do
          [
            %{
              group
              | end_ms: max(group.end_ms, end_ms),
                kinds: Enum.uniq(group.kinds ++ [kind])
            }
            | rest
          ]
        else
          [new_group(start_ms, end_ms, kind, block_id), group | rest]
        end

      {start_ms, end_ms, kind, block_id}, [] ->
        [new_group(start_ms, end_ms, kind, block_id)]
    end)
    |> Enum.reverse()
    |> Enum.map(&away_entry(&1, started_at))
  end

  defp new_group(start_ms, end_ms, kind, block_id),
    do: %{start_ms: start_ms, end_ms: end_ms, kinds: [kind], block_id: block_id}

  defp interval(%{event_type: type} = event, _started_at) do
    duration_ms = int(event.payload["duration_ms"])

    if duration_ms > 0 do
      end_ms = DateTime.to_unix(event.occurred_at, :millisecond)
      [{end_ms - duration_ms, end_ms, away_type(type), event.block_id}]
    else
      []
    end
  end

  defp away_entry(group, started_at) do
    started_ms = DateTime.to_unix(started_at, :millisecond)

    %{
      offset: max(div(group.start_ms - started_ms, 1000), 0),
      type: Enum.find(@away_priority, &(&1 in group.kinds)),
      count: 1,
      duration_ms: group.end_ms - group.start_ms,
      chars: nil,
      split: nil,
      source: nil,
      kinds: group.kinds,
      block_id: group.block_id
    }
  end

  defp covered_by_absence?(%{offset: offset, duration_ms: duration_ms}, away, _started_at) do
    mouse_start = offset * 1000
    mouse_end = mouse_start + duration_ms

    Enum.any?(away, fn entry ->
      away_start = entry.offset * 1000
      mouse_start < away_start + entry.duration_ms and mouse_end > away_start
    end)
  end

  defp entry(%{event_type: type} = event, started_at) when type in @return_types do
    duration_ms = int(event.payload["duration_ms"])

    cond do
      duration_ms <= 0 ->
        []

      type == :mouse_left and duration_ms < @min_mouse_away_ms ->
        []

      true ->
        [
          build_entry(type, offset_of(event, started_at) - div(duration_ms, 1000), event,
            duration_ms: duration_ms
          )
        ]
    end
  end

  defp entry(%{event_type: :paste_detected} = event, started_at) do
    chars = int(event.payload["pasted_chars"])

    if chars >= @min_paste_chars,
      do: [
        build_entry(:paste_detected, offset_of(event, started_at), event,
          chars: chars,
          source: event.payload["source"]
        )
      ],
      else: []
  end

  defp entry(%{event_type: :bulk_insert} = event, started_at),
    do: [
      build_entry(:bulk_insert, offset_of(event, started_at), event,
        chars: int(event.payload["chars"])
      )
    ]

  defp entry(%{event_type: :window_geometry_changed} = event, started_at),
    do: [
      build_entry(:window_geometry_changed, offset_of(event, started_at), event,
        split: event.payload["split"] == true
      )
    ]

  defp entry(%{event_type: type} = event, started_at) when type in @instant_types,
    do: [build_entry(type, offset_of(event, started_at), event, [])]

  defp entry(_event, _started_at), do: []

  defp away_type(:tab_visible), do: :tab_away
  defp away_type(:window_focus), do: :window_away
  defp away_type(type), do: type

  defp build_entry(type, offset, event, extra) do
    %{
      offset: max(offset, 0),
      type: type,
      count: 1,
      duration_ms: extra[:duration_ms],
      chars: extra[:chars],
      split: extra[:split],
      source: extra[:source],
      kinds: [type],
      block_id: event.block_id
    }
  end

  defp incident_entries(submission, started_at) do
    for %{"type" => "silence", "at" => at, "seconds" => seconds} <-
          Map.get(submission.content || %{}, "incidents", []),
        {:ok, at, _} <- [DateTime.from_iso8601(at)] do
      %{
        offset: max(DateTime.diff(at, started_at, :second), 0),
        type: :silence,
        count: 1,
        duration_ms: seconds * 1000,
        chars: nil,
        split: nil,
        source: nil,
        kinds: [:silence],
        block_id: nil
      }
    end
  end

  defp collapse_bursts(entries) do
    entries
    |> Enum.reduce([], fn
      %{type: type} = entry, [%{type: type} = last | rest] when type in @burst_types ->
        if entry.offset - last.offset <= @burst_window_seconds,
          do: [%{last | count: last.count + 1} | rest],
          else: [entry, last | rest]

      entry, acc ->
        [entry | acc]
    end)
    |> Enum.reverse()
  end

  defp offset_of(event, started_at), do: DateTime.diff(event.occurred_at, started_at, :second)

  defp started_at(submission) do
    with iso when is_binary(iso) <- Map.get(submission.content || %{}, "started_at"),
         {:ok, at, _} <- DateTime.from_iso8601(iso) do
      at
    else
      _ -> to_datetime(submission.inserted_at)
    end
  end

  defp to_datetime(%DateTime{} = dt), do: dt
  defp to_datetime(%NaiveDateTime{} = ndt), do: DateTime.from_naive!(ndt, "Etc/UTC")

  defp question_ids(submission) do
    for %{"id" => id} <- Map.get(submission.content || %{}, "questions", []),
        is_binary(id),
        do: id
  end

  defp int(value) when is_integer(value) and value > 0, do: value
  defp int(value) when is_float(value) and value > 0, do: trunc(value)
  defp int(_value), do: 0
end
