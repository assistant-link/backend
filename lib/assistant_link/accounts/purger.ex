defmodule AssistantLink.Accounts.Purger do
  @moduledoc """
  Runs `AssistantLink.Accounts.purge_deleted_accounts/0` a minute after start, then every hour. Nodes
  may run it at the same time: the purge skips accounts another node has claimed.
  """
  use GenServer

  alias AssistantLink.Accounts

  @interval to_timeout(hour: 1)
  # A service restarted more often than the interval would otherwise never purge.
  @first_delay to_timeout(minute: 1)

  def start_link(opts) do
    {first_delay, opts} = Keyword.pop(opts, :first_delay, @first_delay)
    GenServer.start_link(__MODULE__, first_delay, opts)
  end

  @impl GenServer
  def init(first_delay) do
    schedule(first_delay)
    {:ok, :ok}
  end

  @impl GenServer
  def handle_info(:purge, :ok) do
    :ok = Accounts.purge_deleted_accounts()
    schedule(@interval)
    {:noreply, :ok}
  end

  defp schedule(delay), do: Process.send_after(self(), :purge, delay)
end
