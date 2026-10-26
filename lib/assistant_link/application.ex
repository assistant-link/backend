defmodule AssistantLink.Application do
  @moduledoc false

  use Boundary, top_level?: true, deps: [AssistantLink, AssistantLinkWeb]
  use Application

  # Tests start their own Purger: a timed purge in the background would use a test's sandbox connection.
  @purgers if Mix.env() == :test, do: [], else: [AssistantLink.Accounts.Purger]

  @impl true
  def start(_type, _args) do
    children = [
      AssistantLinkWeb.Telemetry,
      AssistantLink.Repo,
      {DNSCluster, query: Application.get_env(:assistant_link, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: AssistantLink.PubSub},
      AssistantLink.Presence,
      {Registry, keys: :unique, name: AssistantLink.Delivery.Registry},
      {DynamicSupervisor, name: AssistantLink.Delivery.Supervisor, strategy: :one_for_one}
    ]

    children =
      children ++
        @purgers ++
        [
          # Start a worker by calling: AssistantLink.Worker.start_link(arg)
          # {AssistantLink.Worker, arg},
          # Start to serve requests, typically the last entry
          AssistantLinkWeb.Endpoint
        ]

    opts = [strategy: :one_for_one, name: AssistantLink.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    AssistantLinkWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
