defmodule Athena.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  @compile {:boundary, ignore: [AthenaWeb.Endpoint, AthenaWeb.Telemetry, AthenaWeb.Presence]}

  use Application

  @impl true
  def start(_type, _args) do
    server_role = Application.get_env(:athena, :server_role)
    runner_family = Application.get_env(:athena, :runner_family)

    topologies = Application.get_env(:libcluster, :topologies) || []

    common_children = [
      %{id: Athena.PG, start: {:pg, :start_link, [Athena.PG]}}
    ]

    children =
      cluster_children(topologies) ++
        common_children ++ children_for_role(server_role, runner_family)

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
  defp children_for_role("runner", runner_family),
    do: [
      {Task.Supervisor, name: Athena.Execution.TaskSupervisor},
      Supervisor.child_spec(
        {Task, fn -> register_runner_in_pg(runner_families(runner_family)) end},
        id: :register_runner_in_pg,
        restart: :temporary
      )
    ]

  defp children_for_role("default", _runner_family),
    do: [
      Athena.Repo,
      {Oban, Application.fetch_env!(:athena, Oban)},
      AthenaWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:athena, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Athena.PubSub},
      AthenaWeb.Presence,
      Athena.Media.EventListener,
      Athena.Content.Listener,
      Athena.Gamification.ActivityListener,
      Supervisor.child_spec({Cachex, name: :account_cache}, id: :account_cache),
      Supervisor.child_spec({Cachex, name: :draft_cache}, id: :draft_cache),
      {Registry, keys: :unique, name: Athena.Engagement.BlockStatsRegistry},
      {DynamicSupervisor, name: Athena.Engagement.BlockStatsSupervisor, strategy: :one_for_one},
      {Registry, keys: :unique, name: Athena.Engagement.ProctoringMonitorRegistry},
      {DynamicSupervisor,
       name: Athena.Engagement.ProctoringMonitorSupervisor, strategy: :one_for_one},
      {Registry, keys: :unique, name: Athena.Engagement.ExamIntegrityStatsRegistry},
      {DynamicSupervisor,
       name: Athena.Engagement.ExamIntegrityStatsSupervisor, strategy: :one_for_one},
      AthenaWeb.Endpoint
    ]

  defp children_for_role("all", runner_family),
    do: children_for_role("runner", runner_family) ++ children_for_role("default", runner_family)

  # A combined ("all") node serves every language, since there's only one of it.
  defp runner_families(nil), do: [:db, :compiled, :script]
  defp runner_families(family), do: [family]

  defp register_runner_in_pg(families) do
    case Process.whereis(Athena.Execution.TaskSupervisor) do
      nil -> :ok
      pid -> Enum.each(families, &:pg.join(Athena.PG, {:code_runners, &1}, pid))
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    # hide from boundary
    apply(AthenaWeb.Endpoint, :config_change, [changed, removed])
    :ok
  end
end
