defmodule AssistantLink.Voice do
  @moduledoc """
  Voice for calls. The app connects to this service over WebRTC (UDP only, no TURN), and a
  `AssistantLink.Voice.Session` relays the call's audio to a realtime voice model behind a
  `AssistantLink.Voice.Vendor`. The voice agent speaks as the Assistant and does the in-call thinking itself;
  what it recognizes and speaks is saved as the call's transcript entries.

  A session runs on the machine that answered the app's offer, for as long as the call is on.
  """
  alias AssistantLink.Accounts.Scope
  alias AssistantLink.Assistants.Assistant
  alias AssistantLink.Calls
  alias AssistantLink.Calls.Call
  alias AssistantLink.Repo
  alias AssistantLink.Voice.Drain
  alias AssistantLink.Voice.Session

  require Logger

  @max_offer_bytes 65_536

  @doc """
  Answers the app's SDP offer for one of the scope's open calls with an SDP answer and starts relaying the
  call's audio to the voice agent. A new offer for the same call replaces its session.

  Returns `{:error, :voice_unavailable}` when WebRTC or the voice model cannot start.
  """
  @spec connect(Scope.t(), String.t(), String.t(), term()) ::
          {:ok, String.t()}
          | {:error, :not_found | :call_not_found | :call_already_ended | :invalid_params | :voice_unavailable}
  def connect(%Scope{} = scope, assistant_id, call_id, offer) do
    with {:ok, call} <- Calls.get_call(scope, assistant_id, call_id),
         :ok <- open(call),
         :ok <- validate_offer(offer),
         :ok <- available(call),
         {:ok, peer_connection} <- peer_connection_options() do
      call = Repo.preload(call, :assistant)
      stop(call.id)

      opts = [
        call: call,
        vendor: vendor(),
        instructions: instructions(call.assistant),
        peer_connection: peer_connection,
        callers: [self() | Process.get(:"$callers", [])]
      ]

      case DynamicSupervisor.start_child(AssistantLink.Voice.Supervisor, {Session, opts}) do
        {:ok, pid} -> Session.answer(pid, offer)
        {:error, _reason} -> {:error, :voice_unavailable}
      end
    end
  end

  defp open(%Call{ended_at: nil}), do: :ok
  defp open(%Call{}), do: {:error, :call_already_ended}

  defp validate_offer(offer) when is_binary(offer) and byte_size(offer) <= @max_offer_bytes do
    case ExSDP.parse(offer) do
      {:ok, %ExSDP{media: media}} ->
        if Enum.any?(media, &(&1.type == :audio)), do: :ok, else: {:error, :invalid_params}

      {:error, _reason} ->
        {:error, :invalid_params}
    end
  end

  defp validate_offer(_offer), do: {:error, :invalid_params}

  defp available(%Call{mode: :realtime_relay}) do
    if Drain.draining?() do
      Logger.warning("Voice chat could not start: this machine is shutting down.")
      {:error, :voice_unavailable}
    else
      :ok
    end
  end

  defp available(%Call{mode: mode}) do
    Logger.warning("Voice chat could not start: the #{mode} mode has no voice yet.")
    {:error, :voice_unavailable}
  end

  @doc "Stops the call's session on this machine, if it has one."
  @spec stop(Ecto.UUID.t()) :: :ok
  def stop(call_id) do
    case Registry.lookup(AssistantLink.Voice.Registry, call_id) do
      [{pid, _value}] ->
        ref = Process.monitor(pid)
        DynamicSupervisor.terminate_child(AssistantLink.Voice.Supervisor, pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          to_timeout(second: 10) -> Process.demonitor(ref, [:flush]) && :ok
        end

      [] ->
        :ok
    end
  end

  @doc "The pid of the call's session on this machine, if it has one."
  @spec session(Ecto.UUID.t()) :: pid() | nil
  def session(call_id) do
    case Registry.lookup(AssistantLink.Voice.Registry, call_id) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  defp vendor, do: Keyword.get(config(), :vendor, AssistantLink.Voice.OpenAI)

  defp config, do: Application.get_env(:assistant_link, __MODULE__, [])

  defp peer_connection_options do
    config = config()

    with {:ok, listen_ip} <- listen_ip(config[:listen_host]) do
      public_ip = config[:public_ip]

      options =
        [audio_codecs: [:opus], video_codecs: []] ++
          if(config[:port_range], do: [ice_port_range: config[:port_range]], else: []) ++
          if(listen_ip, do: [ice_ip_filter: &(&1 == listen_ip)], else: []) ++
          if(public_ip, do: [host_to_srflx_ip_mapper: &srflx_ip(&1, public_ip)], else: [])

      {:ok, options}
    end
  end

  defp listen_ip(nil), do: {:ok, nil}

  defp listen_ip(host) do
    case :inet.getaddr(String.to_charlist(host), :inet) do
      {:ok, ip} ->
        {:ok, ip}

      {:error, reason} ->
        Logger.error("Voice chat could not start: WEBRTC_LISTEN_HOST does not resolve (#{reason}).")
        {:error, :voice_unavailable}
    end
  end

  defp srflx_ip({_a, _b, _c, _d}, public_ip), do: public_ip
  defp srflx_ip(_ipv6, _public_ip), do: nil

  @doc "The voice agent's system prompt for a call with the Assistant."
  @spec instructions(Assistant.t()) :: String.t()
  def instructions(%Assistant{name: name}) do
    """
    You are #{name}, talking with the user on a voice call in the Assistant Link app. To the user you and \
    #{name} are one: when the call starts, greet them briefly as #{name}, and never say you are a separate \
    voice, a different assistant, or a relay.

    Talk the way people talk on a phone call: short, natural sentences, one idea at a time, and let the user \
    interrupt. Do the thinking yourself and answer from what you know. During this call you cannot reach \
    #{name}'s tools, files, or other conversations, so do not hand the request to anyone else. When you do \
    not know something or would need to look it up, say so plainly instead of guessing.
    """
  end
end
