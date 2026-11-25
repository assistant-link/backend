defmodule AssistantLink.Voice.OpenAI do
  @moduledoc """
  OpenAI GPT-Live behind a call. This service is the WebRTC client of the GPT-Live session: the user's Opus
  packets go out on its audio track, the model's audio comes back on it, and the model's transcripts and
  delegations arrive on its `oai-events` data channel.

  The API key is `:api_key`, from `OPENAI_API_KEY`. Without one, calls get `voice_unavailable` and the rest of
  the service runs as usual. Neither the key nor any SDP is logged.

  There is no main-agent channel yet, so the voice agent answers by itself: each delegation is answered at once
  with a note that nothing more can be looked up during the call.
  """
  @behaviour AssistantLink.Voice.Vendor

  use GenServer

  alias AssistantLink.Voice.Vendor
  alias ExWebRTC.DataChannel
  alias ExWebRTC.MediaStreamTrack
  alias ExWebRTC.PeerConnection
  alias ExWebRTC.SessionDescription

  require Logger

  @base_url "https://api.openai.com"
  @model "gpt-live-1.1"
  @gather_timeout to_timeout(second: 5)
  @connect_timeout to_timeout(second: 10)
  @close_timeout to_timeout(second: 2)
  @no_delegation "Nothing more can be looked up during this call. Tell the user so in a few words, and answer " <>
                   "from what you already know if you can."

  @impl Vendor
  def start_link(opts) do
    case GenServer.start_link(__MODULE__, opts) do
      :ignore -> {:error, :voice_unavailable}
      result -> result
    end
  end

  @impl Vendor
  def send_audio(vendor, packet), do: GenServer.cast(vendor, {:audio, packet})

  @impl Vendor
  def close(vendor) do
    GenServer.call(vendor, :close, @close_timeout + to_timeout(second: 1))
  catch
    :exit, _reason -> :ok
  end

  @impl GenServer
  def init(opts) do
    Process.put(:"$callers", Keyword.get(opts, :callers, []))
    config = Keyword.merge(Application.get_env(:assistant_link, __MODULE__, []), Keyword.get(opts, :config, []))

    case config[:api_key] do
      key when is_binary(key) and key != "" ->
        start_session(opts, config, key)

      _missing ->
        Logger.error("Voice chat is unavailable: OPENAI_API_KEY is not set.")
        :ignore
    end
  end

  defp start_session(opts, config, key) do
    {:ok, pc} = PeerConnection.start_link(audio_codecs: [:opus], video_codecs: [])
    track = MediaStreamTrack.new(:audio)

    with {:ok, channel} <- PeerConnection.create_data_channel(pc, "oai-events"),
         {:ok, _sender} <- PeerConnection.add_track(pc, track),
         {:ok, offer} <- PeerConnection.create_offer(pc),
         :ok <- PeerConnection.set_local_description(pc, offer),
         {:ok, sdp} <- await_gathering(pc),
         {:ok, answer} <- create_session(config, key, Keyword.fetch!(opts, :instructions), sdp),
         :ok <- PeerConnection.set_remote_description(pc, %SessionDescription{type: :answer, sdp: answer}),
         :ok <- await_connected(pc) do
      {:ok,
       %{
         session: Keyword.fetch!(opts, :session),
         pc: pc,
         track: track,
         channel: channel.ref,
         started_at: DateTime.utc_now(),
         closing: nil
       }}
    else
      error ->
        if error != {:error, :logged} do
          Logger.error("Voice chat could not start: the OpenAI WebRTC connection failed (#{inspect(error, limit: 5)}).")
        end

        PeerConnection.close(pc)
        :ignore
    end
  end

  defp await_gathering(pc) do
    receive do
      {:ex_webrtc, ^pc, {:ice_gathering_state_change, :complete}} ->
        {:ok, PeerConnection.get_local_description(pc).sdp}
    after
      @gather_timeout -> {:error, :gathering_timeout}
    end
  end

  defp await_connected(pc) do
    receive do
      {:ex_webrtc, ^pc, {:connection_state_change, :connected}} -> :ok
      {:ex_webrtc, ^pc, {:connection_state_change, :failed}} -> {:error, :connection_failed}
    after
      @connect_timeout -> {:error, :connect_timeout}
    end
  end

  defp create_session(config, key, instructions, sdp) do
    body = %{
      session: %{model: config[:model] || @model, instructions: instructions},
      transport: %{type: "webrtc", sdp: sdp}
    }

    [
      base_url: config[:base_url] || @base_url,
      auth: {:bearer, key},
      receive_timeout: to_timeout(second: 15),
      retry: false
    ]
    |> Req.new()
    |> Req.merge(config[:req_options] || [])
    |> Req.post(url: "/v1/live/sessions", json: body)
    |> case do
      {:ok, %Req.Response{status: status, body: %{"transport" => %{"sdp" => answer}}}}
      when status in 200..299 and is_binary(answer) ->
        {:ok, answer}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("Voice chat could not start: OpenAI answered HTTP #{status} (#{inspect(error_code(body))}).")
        {:error, :logged}

      {:error, exception} ->
        Logger.error(
          "Voice chat could not start: OpenAI could not be reached (#{inspect(Map.get(exception, :reason))})."
        )

        {:error, :logged}
    end
  end

  defp error_code(%{"error" => %{"code" => code}}), do: code
  defp error_code(_body), do: nil

  @impl GenServer
  def handle_cast({:audio, packet}, state) do
    PeerConnection.send_rtp(state.pc, state.track.id, ExRTP.Packet.remove_extensions(packet))
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:close, from, state) do
    case PeerConnection.get_data_channel(state.pc, state.channel) do
      %DataChannel{ready_state: ready_state} when ready_state in [:connecting, :open] ->
        if ready_state == :open, do: send_event(state, %{type: "session.close"})
        Process.send_after(self(), :close_timeout, @close_timeout)
        {:noreply, %{state | closing: from}}

      _closed ->
        PeerConnection.close(state.pc)
        {:stop, :normal, :ok, state}
    end
  end

  @impl GenServer
  def handle_info({:ex_webrtc, pc, {:rtp, _track_id, _rid, packet}}, %{pc: pc} = state) do
    send(state.session, {:voice_vendor, self(), {:audio, packet}})
    {:noreply, state}
  end

  def handle_info({:ex_webrtc, pc, {:data_channel_state_change, ref, :open}}, %{pc: pc, channel: ref} = state) do
    if state.closing, do: send_event(state, %{type: "session.close"})
    {:noreply, state}
  end

  def handle_info({:ex_webrtc, pc, {:data, ref, data}}, %{pc: pc, channel: ref} = state) do
    case Jason.decode(data) do
      {:ok, %{"type" => type} = event} -> handle_event(type, event, state)
      _not_an_event -> {:noreply, state}
    end
  end

  def handle_info({:ex_webrtc, pc, {:connection_state_change, connection}}, %{pc: pc} = state)
      when connection in [:failed, :closed] do
    Logger.warning("Voice chat stopped: the OpenAI WebRTC connection is #{connection}.")
    stop(state)
  end

  def handle_info(:close_timeout, state), do: stop(state)

  def handle_info(_message, state), do: {:noreply, state}

  defp handle_event("session.started", _event, state), do: {:noreply, %{state | started_at: DateTime.utc_now()}}

  defp handle_event("session.input_transcript.delta", event, state), do: transcript(state, :user, event)

  defp handle_event("session.output_transcript.delta", event, state), do: transcript(state, :assistant, event)

  defp handle_event("session.delegation.created", %{"delegation" => %{"id" => id}}, state) do
    send_event(state, %{type: "session.commentary.append", delegation_id: id, content: @no_delegation})
    {:noreply, state}
  end

  defp handle_event("error", event, state) do
    Logger.warning("OpenAI voice session error: #{inspect(get_in(event, ["error", "code"]))}.")
    {:noreply, state}
  end

  defp handle_event("session.closed", _event, state), do: stop(state)

  defp handle_event(_type, _event, state), do: {:noreply, state}

  defp transcript(state, speaker, %{"delta" => delta} = event) when is_binary(delta) do
    started_at = offset(state, event["start_ms"]) || DateTime.utc_now()
    ended_at = offset(state, event["end_ms"]) || started_at
    send(state.session, {:voice_vendor, self(), {:transcript, speaker, delta, started_at, ended_at}})
    {:noreply, state}
  end

  defp transcript(state, _speaker, _event), do: {:noreply, state}

  defp offset(state, ms) when is_integer(ms) and ms >= 0, do: DateTime.add(state.started_at, ms, :millisecond)
  defp offset(_state, _ms), do: nil

  defp send_event(state, event), do: PeerConnection.send_data(state.pc, state.channel, Jason.encode!(event))

  defp stop(state) do
    if state.closing, do: GenServer.reply(state.closing, :ok)
    PeerConnection.close(state.pc)
    {:stop, :normal, state}
  end
end
