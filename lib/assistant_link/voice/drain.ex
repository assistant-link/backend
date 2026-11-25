defmodule AssistantLink.Voice.Drain do
  @moduledoc """
  Lets active calls finish when the application stops, as in a deploy. From then on new WebRTC offers get
  `voice_unavailable`, and the shutdown waits until no session runs on this machine, for at most `:drain_timeout`
  milliseconds. It starts after the endpoint so that it stops first, while the endpoint still serves the calls'
  requests.
  """
  use GenServer

  @poll_interval 500

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, shutdown: drain_timeout() + to_timeout(second: 5)}
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Whether this machine is shutting down and takes no new calls."
  @spec draining?() :: boolean()
  def draining?, do: :persistent_term.get(__MODULE__, false)

  defp drain_timeout, do: Keyword.get(Application.get_env(:assistant_link, AssistantLink.Voice, []), :drain_timeout, 0)

  @impl true
  def init(nil) do
    Process.flag(:trap_exit, true)
    :persistent_term.put(__MODULE__, false)
    {:ok, nil}
  end

  @impl true
  def terminate(_reason, nil) do
    :persistent_term.put(__MODULE__, true)
    wait(System.monotonic_time(:millisecond) + drain_timeout())
  end

  defp wait(deadline) do
    if sessions() > 0 and System.monotonic_time(:millisecond) < deadline do
      Process.sleep(@poll_interval)
      wait(deadline)
    else
      :ok
    end
  end

  defp sessions, do: DynamicSupervisor.count_children(AssistantLink.Voice.Supervisor).active
end
