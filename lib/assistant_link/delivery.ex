defmodule AssistantLink.Delivery do
  @moduledoc """
  Delivers a Link's events to its agent connections. One process per online Link holds the one event
  in flight and the retry timer; it exists while the Link has a connection.

  A connection process calls `connect/1` and then gets `{:event_deliver, attempt, event}`. It answers with
  `acknowledge/2` for a result and `fail/2` for an error response to that request. A connection that
  closes, or does not answer within `:attempt_timeout`, fails the attempt too, and the same event goes
  to the Link's next-newest connection that has not failed it. When all failed, the next round starts
  after `:retry_wait` ms, doubling per failed round up to 5 minutes. A new connection resets the wait
  and starts a round at once.

  The process runs again when a connection joins, when a user's message of its Assistant is stored,
  on each acknowledgement, and when the retry timer fires.
  """
  use GenServer, restart: :temporary

  alias AssistantLink.Accounts
  alias AssistantLink.Events
  alias AssistantLink.Events.Event
  alias AssistantLink.Links.Link

  @registry AssistantLink.Delivery.Registry
  @supervisor AssistantLink.Delivery.Supervisor
  @max_wait to_timeout(minute: 5)

  @doc "Registers the calling connection process for its Link's deliveries, starting the Link's process if needed."
  @spec connect(Link.t()) :: :ok
  def connect(%Link{} = link) do
    pid =
      case DynamicSupervisor.start_child(@supervisor, {__MODULE__, link}) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    :ok = GenServer.call(pid, {:connect, self()})
    # The connection gets `:DOWN` if the process crashes, and calls `connect/1` again.
    Process.monitor(pid)
    :ok
  catch
    # The process stopped after its last connection closed.
    :exit, {reason, {GenServer, :call, _call}} when reason in [:noproc, :normal] -> connect(link)
  end

  @doc "Reports that the Link acknowledged `event_id`, an id as the agent sent it."
  @spec acknowledge(Ecto.UUID.t(), term()) :: :ok
  def acknowledge(link_id, event_id), do: GenServer.cast(name(link_id), {:acknowledge, event_id})

  @doc "Reports that the agent answered the request of `attempt` with an error."
  @spec fail(Ecto.UUID.t(), reference()) :: :ok
  def fail(link_id, attempt), do: GenServer.cast(name(link_id), {:fail, attempt})

  defp name(link_id), do: {:via, Registry, {@registry, link_id}}

  def start_link(%Link{} = link), do: GenServer.start_link(__MODULE__, link, name: name(link.id))

  @impl GenServer
  def init(%Link{} = link) do
    :ok = Phoenix.PubSub.subscribe(AssistantLink.PubSub, Accounts.topic(link.account_id))

    {:ok,
     %{
       link_id: link.id,
       assistant_id: link.assistant_id,
       connections: [],
       event: nil,
       attempt: nil,
       retry: nil,
       failed: [],
       wait: nil
     }}
  end

  @impl GenServer
  def handle_call({:connect, pid}, _from, state) do
    Process.monitor(pid)

    state = cancel_retry(%{state | connections: [pid | state.connections], failed: [], wait: nil})
    {:reply, :ok, run(state)}
  end

  @impl GenServer
  def handle_cast({:acknowledge, event_id}, state) do
    :ok = Events.acknowledge(state.link_id, event_id)
    {:noreply, run(state)}
  end

  def handle_cast({:fail, attempt}, %{attempt: %{ref: attempt}} = state), do: {:noreply, fail_attempt(state)}
  def handle_cast({:fail, _earlier_attempt}, state), do: {:noreply, state}

  @impl GenServer
  def handle_info({:attempt_timeout, attempt}, %{attempt: %{ref: attempt}} = state), do: {:noreply, fail_attempt(state)}

  def handle_info(:retry, state), do: {:noreply, run(%{state | failed: [], retry: nil})}

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    state = %{state | connections: List.delete(state.connections, pid), failed: List.delete(state.failed, pid)}

    case state do
      %{connections: []} -> {:stop, :normal, state}
      %{attempt: %{pid: ^pid}} -> {:noreply, deliver(%{state | attempt: nil})}
      _other -> {:noreply, state}
    end
  end

  def handle_info({:event_created, %Event{sender: :user, assistant_id: id}}, %{assistant_id: id} = state),
    do: {:noreply, run(state)}

  def handle_info(_other_notice, state), do: {:noreply, state}

  # The event being delivered is left alone while an attempt is in flight or a retry is waiting.
  # Another one, or none, replaces it with a fresh round.
  defp run(state) do
    event = Events.next_deliverable(state.link_id)

    cond do
      is_nil(event) -> reset(state)
      state.event && event.id == state.event.id -> if state.attempt || state.retry, do: state, else: deliver(state)
      true -> deliver(%{reset(state) | event: event})
    end
  end

  # The timeout of the dropped attempt still arrives; its ref no longer matches.
  defp reset(state), do: %{cancel_retry(state) | attempt: nil, event: nil, failed: [], wait: nil}

  defp deliver(%{event: event} = state) do
    case Enum.find(state.connections, &(&1 not in state.failed)) do
      nil ->
        wait = if state.wait, do: min(state.wait * 2, @max_wait), else: config(:retry_wait)
        %{state | wait: wait, retry: Process.send_after(self(), :retry, wait)}

      pid ->
        ref = make_ref()
        send(pid, {:event_deliver, ref, event})
        Process.send_after(self(), {:attempt_timeout, ref}, config(:attempt_timeout))
        %{state | attempt: %{ref: ref, pid: pid}}
    end
  end

  defp fail_attempt(%{attempt: %{pid: pid}} = state), do: deliver(%{state | attempt: nil, failed: [pid | state.failed]})

  defp config(key), do: :assistant_link |> Application.fetch_env!(__MODULE__) |> Keyword.fetch!(key)

  defp cancel_retry(%{retry: nil} = state), do: state

  defp cancel_retry(%{retry: timer} = state) do
    Process.cancel_timer(timer)
    %{state | retry: nil}
  end
end
