defmodule AssistantLink.Voice.FakeVendor do
  @moduledoc """
  A stand-in voice model for tests and local development without an OpenAI account. It greets the user as the
  Assistant, plays the user's audio back to them, and recognizes as the user's words whatever `hear/2` gives
  it. Tests use it; in dev, `VOICE_VENDOR=fake` selects it.
  """
  @behaviour AssistantLink.Voice.Vendor

  use GenServer

  alias AssistantLink.Voice.Vendor

  @impl Vendor
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl Vendor
  def send_audio(vendor, packet), do: GenServer.cast(vendor, {:audio, packet})

  @impl Vendor
  def close(vendor), do: GenServer.stop(vendor)

  @doc "Has the fake vendor of a call on this machine recognize `text` as the next part of the user's words."
  @spec hear(Ecto.UUID.t(), String.t()) :: :ok
  def hear(call_id, text) do
    [{vendor, _value}] = Registry.lookup(AssistantLink.Voice.Registry, {__MODULE__, call_id})
    GenServer.cast(vendor, {:hear, text})
  end

  @impl GenServer
  def init(opts) do
    session = Keyword.fetch!(opts, :session)
    {:ok, _owner} = Registry.register(AssistantLink.Voice.Registry, {__MODULE__, Keyword.fetch!(opts, :call).id}, nil)
    say(session, :assistant, "Hi, this is #{Keyword.fetch!(opts, :assistant).name}.")
    {:ok, session}
  end

  @impl GenServer
  def handle_cast({:audio, packet}, session) do
    send(session, {:voice_vendor, self(), {:audio, packet}})
    {:noreply, session}
  end

  def handle_cast({:hear, text}, session) do
    say(session, :user, text)
    {:noreply, session}
  end

  defp say(session, speaker, text) do
    now = DateTime.utc_now()
    send(session, {:voice_vendor, self(), {:transcript, speaker, text, now, now}})
  end
end
