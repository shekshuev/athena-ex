defmodule Athena.Engagement do
  @moduledoc """
  Public API for the Engagement context.

  Collects semantic, business-meaningful telemetry about how students move
  through course content (dwell time, scroll depth, video controls, pasted
  answers, backtracking to earlier material, ...) and turns it into metrics a
  teacher can act on and a researcher can analyze - never raw pointer/keystroke
  data.

  Delegates to specialized internal modules:
  - `Events`: recording raw telemetry and reading raw timelines.
  - `Metrics`: turning raw events into the metric catalog (per block type,
    per section, per cohort/student).
  - `BlockStats`: warm, incrementally-updated per-(cohort, block) running
    statistics, used both for nudge decisions and for live dashboard reads -
    without ever issuing a query per incoming event.
  """

  alias Athena.Engagement.Events

  @doc """
  Records one batch of raw events reported by a single Player session, then
  broadcasts each event to its scoped PubSub topics so that any live
  `BlockStats` process and any open teacher "live replay" view pick it up
  incrementally.
  """
  @spec record_events(binary(), binary() | nil, binary(), [map()]) ::
          {:ok, non_neg_integer()} | {:error, :empty}
  def record_events(account_id, cohort_id, session_id, events) do
    case Events.record_events(account_id, cohort_id, session_id, events) do
      {:ok, {count, rows}} ->
        Enum.each(rows, &notify_engagement_subscribers/1)
        {:ok, count}

      {:error, :empty} = error ->
        error
    end
  end

  defdelegate get_session_timeline(account_id, session_id), to: Events
  defdelegate list_events_for_scope(block_ids, cohort_id \\ nil), to: Events

  @doc false
  defp notify_engagement_subscribers(row) do
    event = %{
      block_id: row.block_id,
      section_id: row.section_id,
      account_id: row.account_id,
      cohort_id: row.cohort_id,
      session_id: row.session_id,
      event_type: row.event_type,
      payload: row.payload,
      occurred_at: row.occurred_at
    }

    Phoenix.PubSub.broadcast(
      Athena.PubSub,
      "engagement:#{row.cohort_id}:#{row.block_id}",
      {:engagement_event, event}
    )

    Phoenix.PubSub.broadcast(
      Athena.PubSub,
      "engagement_session:#{row.account_id}:#{row.session_id}",
      {:engagement_event, event}
    )
  end
end
