defmodule AssistantLinkWeb.Connection do
  @moduledoc """
  A live connection over WebSocket: ALP's agent connection (`/alp/v1/connect`) or the app's
  (`/api/v1/connect`). Every text frame is one JSON-RPC 2.0 message (`AssistantLinkWeb.JSONRPC`);
  neither connection implements methods yet.

  - An agent connection keeps its Link online while it is open, records the Link's `last_active_at`
    when it opens and closes, and starts with `connection.ready`.
  - An app connection sends its account's `link.status` changes, and `event.created` and `event.updated`
    with `{"event": event}` for its text messages.

  Both send `connection.closing` and close when their account is deleted. The service pings every
  `:ping_interval` ms, and the connection closes after `:timeout` ms without a frame from the client.
  """
  @behaviour WebSock

  alias AssistantLink.Accounts
  alias AssistantLink.Links
  alias AssistantLinkWeb.API.EventJSON
  alias AssistantLinkWeb.JSONRPC

  @protocol_version "1"

  @doc "Upgrades the request to an agent connection for a paired Link, or an app connection for an account."
  @spec upgrade(Plug.Conn.t(), {:agent, Links.Link.t()} | {:app, Ecto.UUID.t()}) :: Plug.Conn.t()
  def upgrade(conn, role) do
    config = Application.fetch_env!(:assistant_link, __MODULE__)
    state = %{role: role, ping_interval: Keyword.fetch!(config, :ping_interval)}

    conn
    |> WebSockAdapter.upgrade(__MODULE__, state, timeout: Keyword.fetch!(config, :timeout))
    |> Plug.Conn.halt()
  end

  @impl WebSock
  def init(%{role: {:agent, link}} = state) do
    :ok = Accounts.subscribe(link.account_id)
    :ok = Links.connect(link)

    ready =
      JSONRPC.notification("connection.ready", %{
        link_id: link.id,
        assistant_name: link.assistant.name,
        protocol_version: @protocol_version
      })

    {:push, text(ready), schedule_ping(state)}
  end

  def init(%{role: {:app, account_id}} = state) do
    :ok = Accounts.subscribe(account_id)
    {:ok, schedule_ping(state)}
  end

  @impl WebSock
  def handle_in({frame, opcode: :text}, state) do
    case JSONRPC.reply(frame, &JSONRPC.no_methods/2) do
      nil -> {:ok, state}
      reply -> {:push, text(reply), state}
    end
  end

  def handle_in({_frame, opcode: :binary}, state) do
    {:push, text(JSONRPC.error_response(nil, JSONRPC.invalid_request("expected a text frame."))), state}
  end

  @impl WebSock
  def handle_info(:ping, state), do: {:push, {:ping, ""}, schedule_ping(state)}

  def handle_info({:link_status, link_status}, %{role: {:app, _account_id}} = state),
    do: {:push, text(JSONRPC.notification("link.status", link_status)), state}

  def handle_info({:link_status, _link_status}, state), do: {:ok, state}

  def handle_info({notice, event}, %{role: {:app, _account_id}} = state)
      when notice in [:event_created, :event_updated],
      do: {:push, text(JSONRPC.notification(event_method(notice), EventJSON.show(%{event: event}))), state}

  def handle_info({notice, _event}, state) when notice in [:event_created, :event_updated], do: {:ok, state}

  def handle_info(:account_deleted, state) do
    closing = JSONRPC.notification("connection.closing", %{reason: "account_deleted"})
    {:stop, :normal, {1000, "account_deleted"}, [text(closing)], state}
  end

  @impl WebSock
  def terminate(_reason, %{role: {:agent, link}}), do: Links.disconnect(link)
  def terminate(_reason, _state), do: :ok

  defp event_method(:event_created), do: "event.created"
  defp event_method(:event_updated), do: "event.updated"

  defp schedule_ping(state) do
    Process.send_after(self(), :ping, state.ping_interval)
    state
  end

  defp text(message), do: {:text, JSONRPC.encode!(message)}
end
