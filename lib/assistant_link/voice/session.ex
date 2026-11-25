defmodule AssistantLink.Voice.Session do
  @moduledoc """
  One call's voice: the app's WebRTC peer connection on this machine and the `AssistantLink.Voice.Vendor`
  behind it. Opus RTP packets are relayed both ways without decoding.

  Each speaker's recognized or spoken text is saved as one transcript entry until that speaker pauses for
  `:transcript_pause` milliseconds, then the entry gets its `ended_at`. Every save is broadcast as
  `{:call_transcript_entry, entry}`.

  The session stops when the call ends, when the app's connection fails or does not connect in time, when the
  vendor stops, or after the call window.
  """
  use GenServer, restart: :temporary

  alias AssistantLink.Accounts
  alias AssistantLink.Calls
  alias AssistantLink.Calls.Call
  alias AssistantLink.Events.Event
  alias ExWebRTC.MediaStreamTrack
  alias ExWebRTC.PeerConnection
  alias ExWebRTC.SessionDescription

  require Logger

  @answer_timeout to_timeout(second: 40)
  @gather_timeout to_timeout(second: 5)
  @connect_timeout to_timeout(second: 30)
  # Ten seconds of 20 ms Opus packets.
  @max_held_packets 500
  @max_text_length 10_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    %Call{id: call_id} = Keyword.fetch!(opts, :call)
    GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {AssistantLink.Voice.Registry, call_id}})
  end

  @doc "Answers the app's offer, once the vendor is ready. On an error the session stops."
  @spec answer(pid(), String.t()) :: {:ok, String.t()} | {:error, :invalid_params | :voice_unavailable}
  def answer(pid, offer) do
    GenServer.call(pid, {:answer, offer}, @answer_timeout)
  catch
    :exit, reason ->
      Logger.error("Voice chat could not start: the session did not answer (#{inspect(reason, limit: 5)}).")
      DynamicSupervisor.terminate_child(AssistantLink.Voice.Supervisor, pid)
      {:error, :voice_unavailable}
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    Process.put(:"$callers", Keyword.get(opts, :callers, []))
    call = Keyword.fetch!(opts, :call)
    _subscribed = Accounts.subscribe(call.account_id)

    {:ok,
     %{
       call: call,
       vendor_module: Keyword.fetch!(opts, :vendor),
       instructions: Keyword.fetch!(opts, :instructions),
       peer_connection_options: Keyword.fetch!(opts, :peer_connection),
       callers: Keyword.get(opts, :callers, []),
       pause: Keyword.get(config(), :transcript_pause, 1200),
       pc: nil,
       track: nil,
       vendor: nil,
       connected?: false,
       held: [],
       held_count: 0,
       entries: %{}
     }}
  end

  defp config, do: Application.get_env(:assistant_link, AssistantLink.Voice, [])

  @impl true
  def handle_call({:answer, offer}, _from, state) do
    case negotiate(state, offer) do
      {:ok, answer, state} ->
        Process.send_after(self(), :connect_timeout, @connect_timeout)
        remaining = DateTime.diff(Calls.window_end(state.call), DateTime.utc_now(), :millisecond)
        Process.send_after(self(), :max_duration, max(remaining, 0))
        {:reply, {:ok, answer}, state}

      {:error, reason, state} ->
        {:stop, :normal, {:error, reason}, state}
    end
  end

  defp negotiate(state, offer) do
    case PeerConnection.start_link(state.peer_connection_options) do
      {:ok, pc} -> negotiate(%{state | pc: pc}, pc, offer)
      {:error, reason} -> unavailable(state, {:peer_connection, reason})
    end
  end

  defp negotiate(state, pc, offer) do
    track = MediaStreamTrack.new(:audio)

    with :ok <- set_offer(pc, offer),
         {:ok, _sender} <- PeerConnection.add_track(pc, track),
         {:ok, vendor} <- start_vendor(state) do
      state = %{state | track: track, vendor: vendor}

      with {:ok, answer} <- PeerConnection.create_answer(pc),
           :ok <- PeerConnection.set_local_description(pc, answer),
           {:ok, sdp} <- await_gathering(pc) do
        {:ok, sdp, state}
      else
        {:error, reason} -> unavailable(state, reason)
      end
    else
      {:error, :invalid_params} -> {:error, :invalid_params, state}
      {:error, :voice_unavailable} -> {:error, :voice_unavailable, state}
      {:error, reason} -> unavailable(state, reason)
    end
  end

  defp set_offer(pc, offer) do
    case PeerConnection.set_remote_description(pc, %SessionDescription{type: :offer, sdp: offer}) do
      :ok -> :ok
      {:error, _reason} -> {:error, :invalid_params}
    end
  end

  defp start_vendor(state) do
    state.vendor_module.start_link(
      session: self(),
      call: state.call,
      assistant: state.call.assistant,
      instructions: state.instructions,
      callers: [self() | state.callers]
    )
  end

  defp await_gathering(pc) do
    receive do
      {:ex_webrtc, ^pc, {:ice_gathering_state_change, :complete}} ->
        %SessionDescription{sdp: sdp} = PeerConnection.get_local_description(pc)
        if sdp =~ "a=candidate:", do: {:ok, sdp}, else: {:error, :no_candidates}
    after
      @gather_timeout -> {:error, :gathering_timeout}
    end
  end

  defp unavailable(state, reason) do
    Logger.error("Voice chat could not start: WebRTC failed (#{inspect(reason, limit: 5)}).")
    {:error, :voice_unavailable, state}
  end

  @impl true
  def handle_info({:ex_webrtc, pc, {:rtp, _track_id, _rid, packet}}, %{pc: pc} = state) do
    state.vendor_module.send_audio(state.vendor, packet)
    {:noreply, state}
  end

  def handle_info({:ex_webrtc, pc, {:connection_state_change, :connected}}, %{pc: pc} = state) do
    state.held |> Enum.reverse() |> Enum.each(&play(state, &1))
    {:noreply, %{state | connected?: true, held: [], held_count: 0}}
  end

  def handle_info({:ex_webrtc, pc, {:connection_state_change, connection}}, %{pc: pc} = state)
      when connection in [:failed, :closed] do
    Logger.info("Voice chat stopped: the app's WebRTC connection is #{connection}.")
    {:stop, :normal, state}
  end

  def handle_info({:ex_webrtc, _pc, _message}, state), do: {:noreply, state}

  def handle_info({:voice_vendor, vendor, {:audio, packet}}, %{vendor: vendor, connected?: true} = state) do
    play(state, packet)
    {:noreply, state}
  end

  # The vendor is ready, and may start speaking, before the app has the answer and has connected; packets sent
  # before then would be dropped, so the greeting waits for the app.
  def handle_info({:voice_vendor, vendor, {:audio, packet}}, %{vendor: vendor} = state) do
    if state.held_count < @max_held_packets do
      {:noreply, %{state | held: [packet | state.held], held_count: state.held_count + 1}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:voice_vendor, _vendor, {:transcript, speaker, text, started_at, ended_at}}, state)
      when speaker in [:user, :assistant] do
    {:noreply, transcribe(state, speaker, text, started_at, ended_at)}
  end

  def handle_info({:pause, speaker, ref}, state) do
    case state.entries do
      %{^speaker => %{ref: ^ref}} -> {:noreply, finish(state, speaker)}
      _entries -> {:noreply, state}
    end
  end

  def handle_info(:connect_timeout, %{connected?: true} = state), do: {:noreply, state}

  def handle_info(:connect_timeout, state) do
    Logger.info("Voice chat stopped: the app did not connect over WebRTC in time.")
    {:stop, :normal, state}
  end

  def handle_info(:max_duration, state), do: {:stop, :normal, state}

  def handle_info({:event_updated, %Event{call: %Call{id: id, ended_at: %DateTime{}}}}, %{call: %Call{id: id}} = state),
    do: {:stop, :normal, state}

  def handle_info(:account_deleted, state), do: {:stop, :normal, state}

  def handle_info({:EXIT, pid, _reason}, state) when pid in [state.vendor, state.pc] do
    {:stop, :normal, %{state | vendor: if(pid == state.vendor, do: nil, else: state.vendor)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp play(state, packet),
    do: PeerConnection.send_rtp(state.pc, state.track.id, ExRTP.Packet.remove_extensions(packet))

  defp transcribe(state, speaker, text, started_at, ended_at) do
    case state.entries do
      %{^speaker => open} when byte_size(open.entry.text) + byte_size(text) <= @max_text_length ->
        save(state, speaker, Calls.change_transcript_entry(open.entry, %{text: open.entry.text <> text}), ended_at)

      _entries ->
        state = finish(state, speaker)
        attrs = %{speaker: speaker, text: String.trim_leading(text), started_at: started_at}
        save(state, speaker, Calls.add_transcript_entry(state.call, attrs), ended_at)
    end
  end

  defp save(state, speaker, {:ok, entry}, ended_at) do
    ref = make_ref()
    Process.send_after(self(), {:pause, speaker, ref}, state.pause)
    previous = List.wrap(get_in(state.entries, [speaker, :ended_at]))
    ended_at = Enum.max([ended_at, entry.started_at | previous], DateTime)
    put_in(state.entries[speaker], %{entry: entry, ended_at: ended_at, ref: ref})
  end

  defp save(state, _speaker, {:error, changeset}, _ended_at) do
    Logger.warning("Could not save a voice transcript entry: #{inspect(Keyword.keys(changeset.errors))}.")
    state
  end

  defp finish(state, speaker) do
    case Map.pop(state.entries, speaker) do
      {%{entry: entry, ended_at: ended_at}, entries} ->
        attrs = %{text: String.trim_trailing(entry.text), ended_at: ended_at}

        with {:error, changeset} <- Calls.change_transcript_entry(entry, attrs) do
          Logger.warning("Could not end a voice transcript entry: #{inspect(Keyword.keys(changeset.errors))}.")
        end

        %{state | entries: entries}

      {nil, _entries} ->
        state
    end
  end

  @impl true
  def terminate(_reason, state) do
    state = Enum.reduce(Map.keys(state.entries), state, &finish(&2, &1))
    if state.vendor, do: state.vendor_module.close(state.vendor)
    if state.pc, do: PeerConnection.close(state.pc)
    :ok
  end
end
