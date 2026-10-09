defmodule AssistantLink.Presence do
  @moduledoc """
  Which Assistant Links have an agent connected right now, held in memory only. Each agent connection
  process tracks itself under its Link's id on its account's topic (`topic/1`), so a Link is online
  while any of them is alive, on any node.

  Each connection's meta holds the time it last recorded as the Link's `last_active_at`. When a Link
  comes online or its last connection goes, the account's subscribers get `{:link_status, ...}` with
  that time (see `AssistantLink.Accounts.subscribe/1`).
  """
  use Phoenix.Presence, otp_app: :assistant_link, pubsub_server: AssistantLink.PubSub

  @spec topic(Ecto.UUID.t()) :: String.t()
  def topic(account_id), do: "links:" <> account_id

  @spec online?(Ecto.UUID.t(), Ecto.UUID.t()) :: boolean()
  def online?(account_id, link_id), do: get_by_key(topic(account_id), link_id) != []

  @impl Phoenix.Presence
  def init(_opts), do: {:ok, %{}}

  @impl Phoenix.Presence
  def handle_metas("links:" <> account_id, %{joins: joins, leaves: leaves}, presences, state) do
    changes =
      for link_id <- Enum.uniq(Map.keys(joins) ++ Map.keys(leaves)),
          status = changed_status(link_id, joins, leaves, presences),
          do: %{link_id: link_id, status: status, last_active_at: last_active_at(status, joins, leaves, link_id)}

    # Every node runs this callback for every diff, so each one notifies only its own subscribers.
    for change <- changes do
      Phoenix.PubSub.local_broadcast(
        AssistantLink.PubSub,
        AssistantLink.Accounts.topic(account_id),
        {:link_status, change}
      )
    end

    {:ok, state}
  end

  defp changed_status(link_id, joins, leaves, presences) do
    connections = length(Map.get(presences, link_id, []))
    connections_before = connections - count_metas(joins, link_id) + count_metas(leaves, link_id)

    cond do
      connections > 0 and connections_before == 0 -> :online
      connections == 0 and connections_before > 0 -> :offline
      true -> nil
    end
  end

  defp count_metas(diff, link_id), do: length(metas(diff, link_id))

  defp last_active_at(:online, joins, _leaves, link_id), do: latest_active_at(metas(joins, link_id))
  defp last_active_at(:offline, _joins, leaves, link_id), do: latest_active_at(metas(leaves, link_id))

  defp latest_active_at(metas), do: metas |> Enum.map(& &1.active_at) |> Enum.max(DateTime)

  defp metas(diff, link_id), do: diff |> Map.get(link_id, %{metas: []}) |> Map.fetch!(:metas)
end
