defmodule Athena.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  @compile {:boundary, ignore: [AthenaWeb.Endpoint, AthenaWeb.Telemetry]}

  use Application

  @impl true
  def start(_type, _args) do
    server_role = Application.get_env(:athena, :server_role) || "default"

    topologies = Application.get_env(:libcluster, :topologies)

    children =
      [
        Athena.Repo,
        {Oban, Application.fetch_env!(:athena, Oban)},
        {Cluster.Supervisor, [topologies, [name: Athena.ClusterSupervisor]]}
      ] ++ children_for_role(server_role)

    opts = [strategy: :one_for_one, name: Athena.Supervisor]

    Supervisor.start_link(children, opts)
  end

  @doc false
  defp children_for_role("runner") do
    [
      {Task.Supervisor, name: {:via, :global, :code_runner}}
    ]
  end

  defp children_for_role("default") do
    [
      AthenaWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:athena, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Athena.PubSub},
      Athena.Media.EventListener,
      Athena.Content.Listener,
      {Cachex, name: :account_cache},
      AthenaWeb.Endpoint
    ]
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
