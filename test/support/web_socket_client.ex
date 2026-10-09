defmodule AssistantLinkWeb.WebSocketClient do
  @moduledoc """
  A WebSocket client for tests, run against a real server started with `start_server/1`. It sends the
  test process what it receives as `{:ws, client, event}`:

  - `{:text, json}` for each text frame, decoded
  - `{:ping, payload}` for each ping, which it answers unless connected with `pong: false`
  - `{:closed, code, reason}` when the server closes the connection
  """
  use GenServer

  @doc "Setup helper that serves the endpoint on a free port and stores the port in the test context."
  def start_server(_context) do
    server = ExUnit.Callbacks.start_supervised!({Bandit, plug: AssistantLinkWeb.Endpoint, ip: :loopback, port: 0})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    %{port: port}
  end

  @doc """
  Opens a WebSocket at `path` with an optional bearer token. Returns `{:error, {status, body}}` when
  the server refuses the upgrade.
  """
  def open(port, path, token, opts \\ []) do
    GenServer.start(__MODULE__, {self(), port, path, token, Keyword.get(opts, :pong, true)})
  end

  def send_text(client, text), do: GenServer.call(client, {:send, {:text, text}})

  def send_binary(client, data), do: GenServer.call(client, {:send, {:binary, data}})

  @doc "Closes the connection cleanly and waits for the server to acknowledge it."
  def close(client), do: GenServer.call(client, :close)

  @impl GenServer
  def init({owner, port, path, token, pong?}) do
    {:ok, conn} = Mint.HTTP.connect(:http, "localhost", port, protocols: [:http1])
    headers = if token, do: [{"authorization", "Bearer " <> token}], else: []
    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, path, headers)

    case await_upgrade(conn, ref, %{}) do
      {:ok, conn, websocket, early_data} ->
        Process.link(owner)
        state = %{owner: owner, conn: conn, ref: ref, websocket: websocket, pong?: pong?, closing: nil, closed?: false}
        {:ok, handle_part({:data, ref, early_data}, state)}

      {:error, status, body} ->
        Mint.HTTP.close(conn)
        {:stop, {status, body}}
    end
  end

  defp await_upgrade(conn, ref, response) do
    receive do
      message ->
        {:ok, conn, parts} = Mint.WebSocket.stream(conn, message)
        response = Enum.reduce(parts, response, &collect(&1, ref, &2))

        case response do
          %{done: true, status: 101} ->
            {:ok, conn, websocket} = Mint.WebSocket.new(conn, ref, 101, response.headers)
            # Frames the server sent right after accepting arrive as the upgrade response's body.
            {:ok, conn, websocket, Map.get(response, :body, "")}

          %{done: true, status: status} ->
            {:error, status, Jason.decode!(Map.get(response, :body, ""))}

          _incomplete ->
            await_upgrade(conn, ref, response)
        end
    end
  end

  defp collect({:status, ref, status}, ref, response), do: Map.put(response, :status, status)
  defp collect({:headers, ref, headers}, ref, response), do: Map.put(response, :headers, headers)

  defp collect({:data, ref, data}, ref, response), do: Map.update(response, :body, data, &(&1 <> data))
  defp collect({:done, ref}, ref, response), do: Map.put(response, :done, true)

  @impl GenServer
  def handle_call({:send, frame}, _from, state), do: {:reply, :ok, send_frame(state, frame)}

  def handle_call(:close, from, state), do: {:noreply, %{send_frame(state, {:close, 1000, ""}) | closing: from}}

  @impl GenServer
  def handle_info(message, state) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, parts} ->
        state = Enum.reduce(parts, %{state | conn: conn}, &handle_part/2)
        if state.closed?, do: {:stop, :normal, state}, else: {:noreply, state}

      {:error, _conn, %Mint.TransportError{reason: :closed}, _parts} ->
        {:stop, :normal, state}

      :unknown ->
        {:noreply, state}
    end
  end

  defp handle_part({:data, _ref, data}, state) do
    {:ok, websocket, frames} = Mint.WebSocket.decode(state.websocket, data)
    Enum.reduce(frames, %{state | websocket: websocket}, &handle_frame/2)
  end

  defp handle_part(_part, state), do: state

  defp handle_frame({:text, text}, state) do
    send(state.owner, {:ws, self(), {:text, Jason.decode!(text)}})
    state
  end

  defp handle_frame({:ping, payload}, state) do
    send(state.owner, {:ws, self(), {:ping, payload}})
    if state.pong?, do: send_frame(state, {:pong, payload}), else: state
  end

  defp handle_frame({:close, code, reason}, state) do
    if state.closing do
      GenServer.reply(state.closing, :ok)
      %{state | closed?: true}
    else
      send(state.owner, {:ws, self(), {:closed, code, reason}})
      %{send_frame(state, {:close, code, ""}) | closed?: true}
    end
  end

  defp send_frame(state, frame) do
    {:ok, websocket, data} = Mint.WebSocket.encode(state.websocket, frame)
    {:ok, conn} = Mint.WebSocket.stream_request_body(state.conn, state.ref, data)
    %{state | conn: conn, websocket: websocket}
  end
end
