defmodule Athena.Engagement.Events do
  @moduledoc """
  Internal business logic for recording and reading raw engagement events.

  Writes are batched and untrusted-but-server-normalized (the client reports
  its own event stream; `account_id`/`session_id`/`section_id` are always
  attached server-side by the caller, never taken from the payload as-is).
  """

  import Ecto.Query
  alias Athena.Repo
  alias Athena.Engagement.Event

  @doc """
  Inserts a batch of raw events for one account/session in a single
  `insert_all`. Events are trusted server telemetry (attached by the Player,
  not user-editable business data), so no per-row changeset validation runs
  on the hot path.
  """
  @spec record_events(binary(), binary() | nil, binary(), [map()]) ::
          {:ok, {non_neg_integer(), nil}} | {:error, :empty}
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
  Raw events for a scope (block ids, optionally a cohort) - used only for the
  bootstrap query inside `Athena.Engagement.BlockStats`, not exposed as part
  of the public dashboard API.
  """
  @spec list_events_for_scope([binary()], binary() | nil) :: [Event.t()]
  def list_events_for_scope(block_ids, cohort_id \\ nil)

  def list_events_for_scope(block_ids, nil) do
    Event
    |> where([e], e.block_id in ^block_ids)
    |> Repo.all()
  end

  def list_events_for_scope(block_ids, cohort_id) do
    Event
    |> where([e], e.block_id in ^block_ids and e.cohort_id == ^cohort_id)
    |> Repo.all()
  end
end
