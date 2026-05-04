defmodule Athena.Content.Listener do
  @moduledoc """
  Listens to domain events from other contexts (like Identity)
  and performs necessary cleanups or updates in the Content context.
  """
  use GenServer
  require Logger

  alias Athena.Repo
  alias Athena.Content.{CourseShare, LibraryBlockShare}
  import Ecto.Query

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    Phoenix.PubSub.subscribe(Athena.PubSub, "identity:events")
    Logger.info("[Content.Listener] Subscribed to identity:events")
    {:ok, state}
  end

  @impl true
  def handle_info({:account_deleted, account_id}, state) do
    Logger.info("[Content.Listener] Cleaning up shares for deleted account: #{account_id}")

    Repo.delete_all(from cs in CourseShare, where: cs.account_id == ^account_id)
    Repo.delete_all(from lbs in LibraryBlockShare, where: lbs.account_id == ^account_id)

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
