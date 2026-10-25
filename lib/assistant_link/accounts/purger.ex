defmodule AssistantLink.Accounts.Purger do
  @moduledoc """
  Runs `AssistantLink.Accounts.purge_deleted_accounts/0` every hour. Nodes may run it at the same
  time: the purge skips accounts another node has claimed.
  """
  use GenServer

  alias AssistantLink.Accounts

  @interval to_timeout(hour: 1)

  def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, opts)

  @impl GenServer
  def init(:ok) do
    schedule()
    {:ok, :ok}
  end

  @impl GenServer
  def handle_info(:purge, :ok) do
    :ok = Accounts.purge_deleted_accounts()
    schedule()
    {:noreply, :ok}
  end

  defp schedule, do: Process.send_after(self(), :purge, @interval)
end
