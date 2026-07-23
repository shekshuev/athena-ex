defmodule Athena.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  @compile {:boundary, ignore: [AthenaWeb.Endpoint, AthenaWeb.Telemetry]}

  use Application

  @impl true
  def start(_type, _args) do
    server_role = Application.get_env(:athena, :server_role)

    topologies = Application.get_env(:libcluster, :topologies) || []

    common_children = [
      %{id: Athena.PG, start: {:pg, :start_link, [Athena.PG]}}
    ]

    children =
      cluster_children(topologies) ++ common_children ++ children_for_role(server_role)

    opts = [strategy: :one_for_one, name: Athena.Supervisor]

    Supervisor.start_link(children, opts)
  end

  @doc false
  defp cluster_children([]), do: []

  defp cluster_children(topologies),
    do: [
      {Cluster.Supervisor, [topologies, [name: Athena.ClusterSupervisor]]}
    ]

  @doc false
  defp children_for_role("runner"),
    do: [
      {Task.Supervisor, name: Athena.Execution.TaskSupervisor},
      Supervisor.child_spec(
        {Task,
         fn ->
           case Process.whereis(Athena.Execution.TaskSupervisor) do
             nil -> :ok
             pid -> :pg.join(Athena.PG, :code_runners, pid)
           end
         end},
        id: :register_runner_in_pg,
        restart: :temporary
      )
    ]

  defp children_for_role("default"),
    do: [
      Athena.Repo,
      {Oban, Application.fetch_env!(:athena, Oban)},
      AthenaWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:athena, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Athena.PubSub},
      Athena.Media.EventListener,
      Athena.Content.Listener,
      Supervisor.child_spec({Cachex, name: :account_cache}, id: :account_cache),
      Supervisor.child_spec({Cachex, name: :draft_cache}, id: :draft_cache),
      AthenaWeb.Endpoint
    ]

  defp children_for_role(_), do: children_for_role("runner") ++ children_for_role("default")

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    # hide from boundary
    apply(AthenaWeb.Endpoint, :config_change, [changed, removed])
    :ok
  end
end
