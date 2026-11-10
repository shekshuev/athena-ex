defmodule AthenaWeb.LearnLive.ExamTelemetry do
  @moduledoc """
  Bounds untrusted exam batches before normalization, database writes and scoring.
  Limits reduce event flooding; accepted browser events remain untrusted.
  """

  alias Athena.Engagement

  @max_batch 50
  @window_ms 10_000
  @max_events_per_window 200
  @server_events ~w(answer_changed answer_selected first_interaction code_run_attempt code_run_result)

  def normalize_batch(events, socket) do
    now = System.monotonic_time(:millisecond)
    {since, used} = socket.assigns[:telemetry_budget] || {now, 0}
    {since, used} = if now - since >= @window_ms, do: {now, 0}, else: {since, used}

    allowed_ids =
      MapSet.new([socket.assigns.block.id | Enum.map(socket.assigns.questions, & &1.id)])

    {normalized, used} =
      if is_list(events) and length(Enum.take(events, @max_batch + 1)) <= @max_batch and
           used + length(events) <= @max_events_per_window do
        normalized =
          events
          |> Enum.filter(fn event ->
            is_map(event) and MapSet.member?(allowed_ids, event["block_id"]) and
              event["event_type"] not in @server_events and
              is_map(event["payload"] || %{}) and
              :erlang.external_size(event["payload"] || %{}) <= 2_048
          end)
          |> Enum.map(&Engagement.normalize_event(&1, socket.assigns.block.section_id))
          |> Enum.reject(&is_nil/1)

        {normalized, used + length(events)}
      else
        {[], @max_events_per_window}
      end

    {normalized, Phoenix.Component.assign(socket, :telemetry_budget, {since, used})}
  end
end
