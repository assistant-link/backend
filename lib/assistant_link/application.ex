defmodule AssistantLink.Application do
  @moduledoc false

  use Boundary, top_level?: true, deps: [AssistantLink, AssistantLinkWeb]
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      AssistantLinkWeb.Telemetry,
      AssistantLink.Repo,
      {DNSCluster, query: Application.get_env(:assistant_link, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: AssistantLink.PubSub},
      AssistantLink.Presence,
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
