defmodule Athena.Media.EventListener do
  @moduledoc """
  Listens for domain events from other contexts (like Identity) 
  and reacts to them to maintain data consistency in Media.
  """
  use GenServer
  require Logger
  alias Athena.Media

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    Phoenix.PubSub.subscribe(Athena.PubSub, "identity:events")
    Logger.info("[Media.EventListener] Subscribed to identity:events")
    {:ok, state}
  end

  @impl true
  def handle_info({:role_deleted, role_id}, state) do
    Logger.info("[Media.EventListener] Received role_deleted for role_id: #{role_id}")

    Media.delete_quota(role_id)

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}
end
