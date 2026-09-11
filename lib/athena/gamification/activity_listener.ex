defmodule Athena.Gamification.ActivityListener do
  @moduledoc """
  Listens to learning-activity domain events from the Learning context and
  reacts to them in Gamification — Learning broadcasts facts on
  `"learning_events"` without knowing Gamification exists.
  """
  use GenServer
  require Logger

  alias Athena.Gamification.{XpLedger, Combo, Badges}

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    Phoenix.PubSub.subscribe(Athena.PubSub, "learning_events")
    Phoenix.PubSub.subscribe(Athena.PubSub, "grading:updates")
    Logger.info("[Gamification.ActivityListener] Subscribed to learning_events, grading:updates")
    {:ok, state}
  end

  @impl true
  def handle_info({:block_completed, payload}, state) do
    guarded(fn ->
      XpLedger.record_activity(payload)
      Badges.evaluate_for_account(payload.account_id)
    end)

    {:noreply, state}
  end

  def handle_info({:submission_changed, submission}, state) do
    guarded(fn ->
      Combo.record_result(submission)
      Badges.evaluate_for_account(submission.account_id)
    end)

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # A crash here would restart this singleton listener repeatedly under
  # load (or trip the app supervisor's restart intensity entirely), so
  # failures are logged and dropped rather than propagated — consistent
  # with PubSub already being a fire-and-forget, at-most-once channel.
  defp guarded(fun) do
    fun.()
  rescue
    error ->
      Logger.error(
        "[Gamification.ActivityListener] #{Exception.format(:error, error, __STACKTRACE__)}"
      )
  end
end
