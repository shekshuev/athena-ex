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
  """

  import Ecto.Query

  alias Athena.Engagement.Event
  alias Athena.Repo

  @max_events 1000
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

  @return_types [:tab_visible, :window_focus, :fullscreen_exit, :offline_period, :mouse_left]

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

    submission
    |> fetch_events(block_ids, started_at)
    |> Enum.flat_map(&entry(&1, started_at))
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

  defp entry(%{event_type: type} = event, started_at) when type in @return_types do
    duration_ms = int(event.payload["duration_ms"])

    cond do
      duration_ms <= 0 ->
        []

      type == :mouse_left and duration_ms < @min_mouse_away_ms ->
        []

      true ->
        [
          build_entry(
            away_type(type),
            offset_of(event, started_at) - div(duration_ms, 1000),
            event, duration_ms: duration_ms)
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
