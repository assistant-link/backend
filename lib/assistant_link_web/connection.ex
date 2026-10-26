defmodule AssistantLinkWeb.Connection do
  @moduledoc """
  A live connection over WebSocket: ALP's agent connection (`/alp/v1/connect`) or the app's
  (`/api/v1/connect`). Every text frame is one JSON-RPC 2.0 message (`AssistantLinkWeb.JSONRPC`);
  neither connection implements methods yet.

  - An agent connection keeps its Link online while it is open, records the Link's `last_active_at`
    when it opens and closes, and starts with `connection.ready`. It sends the events that
    `AssistantLink.Delivery` hands it as `event.deliver` requests, numbered by its own counter, and
    reports the agent's answers back.
  - An app connection sends its account's `link.status` changes, and `event.created` and `event.updated`
    with `{"event": event}` for its text messages.

  Both send `connection.closing` and close when their account is deleted. The service pings every
  `:ping_interval` ms, and the connection closes after `:timeout` ms without a frame from the client.
  """
  @behaviour WebSock

  alias AssistantLink.Accounts
  alias AssistantLink.Delivery
  alias AssistantLink.Links
  alias AssistantLinkWeb.API.EventJSON
  alias AssistantLinkWeb.JSONRPC

  @protocol_version "1"

  @doc "Upgrades the request to an agent connection for a paired Link, or an app connection for an account."
  @spec upgrade(Plug.Conn.t(), {:agent, Links.Link.t()} | {:app, Ecto.UUID.t()}) :: Plug.Conn.t()
  def upgrade(conn, role) do
    config = Application.fetch_env!(:assistant_link, __MODULE__)
    state = %{role: role, ping_interval: Keyword.fetch!(config, :ping_interval), next_request_id: 1, request: nil}

    conn
    |> WebSockAdapter.upgrade(__MODULE__, state, timeout: Keyword.fetch!(config, :timeout))
    |> Plug.Conn.halt()
  end

  @impl WebSock
  def init(%{role: {:agent, link}} = state) do
    case Accounts.subscribe(link.account_id) do
      :ok ->
        :ok = Links.connect(link)
        :ok = Delivery.connect(link)

        ready =
          JSONRPC.notification("connection.ready", %{
            link_id: link.id,
            assistant_name: link.assistant.name,
            protocol_version: @protocol_version
          })

        {:push, text(ready), schedule_ping(state)}

      {:error, :account_deleted} ->
        close_account_deleted(Map.put(state, :closed_before_connect, true))
    end
  end

  def init(%{role: {:app, account_id}} = state) do
    case Accounts.subscribe(account_id) do
      :ok -> {:ok, schedule_ping(state)}
      {:error, :account_deleted} -> close_account_deleted(state)
    end
  end

  @impl WebSock
  def handle_in({frame, opcode: :text}, state) do
    decoded = JSONRPC.decode(frame)

    with {:ok, {:response, id, outcome}} <- decoded,
         {:agent, link} <- state.role do
      handle_response(link, id, outcome, state)
    else
      _not_an_agent_response ->
        case JSONRPC.reply_to(decoded, &JSONRPC.no_methods/2) do
          nil -> {:ok, state}
          reply -> {:push, text(reply), state}
        end
    end
  end

  def handle_in({_frame, opcode: :binary}, state) do
    {:push, text(JSONRPC.error_response(nil, JSONRPC.invalid_request("expected a text frame."))), state}
  end

  # A result acknowledges an event whichever request it answers, however late. An error only fails
  # the attempt that is waiting for it.
  defp handle_response(link, _id, {:ok, %{"event_id" => event_id}}, state) do
    Delivery.acknowledge(link.id, event_id)
    {:ok, state}
  end

  defp handle_response(link, id, {:error, _error}, %{request: {id, attempt}} = state) do
    Delivery.fail(link.id, attempt)
    {:ok, state}
  end

  defp handle_response(_link, _id, _outcome, state), do: {:ok, state}

  @impl WebSock
  def handle_info(:ping, state), do: {:push, {:ping, ""}, schedule_ping(state)}

  def handle_info({:event_deliver, attempt, event}, %{next_request_id: id} = state) do
    request = JSONRPC.request(id, "event.deliver", EventJSON.delivery(event))
    {:push, text(request), %{state | next_request_id: id + 1, request: {id, attempt}}}
  end

  def handle_info({:link_status, link_status}, %{role: {:app, _account_id}} = state),
    do: {:push, text(JSONRPC.notification("link.status", link_status)), state}

  def handle_info({:link_status, _link_status}, state), do: {:ok, state}

  def handle_info({notice, event}, %{role: {:app, _account_id}} = state)
      when notice in [:event_created, :event_updated],
      do: {:push, text(JSONRPC.notification(event_method(notice), EventJSON.show(%{event: event}))), state}

  def handle_info({notice, _event}, state) when notice in [:event_created, :event_updated], do: {:ok, state}

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, %{role: {:agent, link}} = state) do
    :ok = Delivery.connect(link)
    {:ok, state}
  end

  def handle_info(:account_deleted, state), do: close_account_deleted(state)

  @impl WebSock
  def terminate(_reason, %{closed_before_connect: true}), do: :ok
  def terminate(_reason, %{role: {:agent, link}}), do: Links.disconnect(link)
  def terminate(_reason, _state), do: :ok

  defp close_account_deleted(state) do
    closing = JSONRPC.notification("connection.closing", %{reason: "account_deleted"})
    {:stop, :normal, {1000, "account_deleted"}, [text(closing)], state}
  end

  defp event_method(:event_created), do: "event.created"
  defp event_method(:event_updated), do: "event.updated"

  defp schedule_ping(state) do
    Process.send_after(self(), :ping, state.ping_interval)
    state
  end

  defp text(message), do: {:text, JSONRPC.encode!(message)}
end
