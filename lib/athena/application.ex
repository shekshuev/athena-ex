defmodule Athena.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      AthenaWeb.Telemetry,
      Athena.Repo,
      {DNSCluster, query: Application.get_env(:athena, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Athena.PubSub},
      # Start a worker by calling: Athena.Worker.start_link(arg)
      # {Athena.Worker, arg},
      # Start to serve requests, typically the last entry
      {Cachex, name: :account_cache},
      AthenaWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Athena.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AthenaWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
