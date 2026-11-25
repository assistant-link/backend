defmodule AssistantLink.WebRTCClient do
  @moduledoc """
  A WebRTC peer for tests, which plays the app or the vendor. It runs in the test process, which gets its
  `{:ex_webrtc, pc, message}` messages. Loopback interfaces carry no ICE candidates, so peers connect over the
  host's other interfaces.
  """
  import ExUnit.Assertions

  alias ExWebRTC.MediaStreamTrack
  alias ExWebRTC.PeerConnection
  alias ExWebRTC.SessionDescription

  @options [audio_codecs: [:opus], video_codecs: []]

  @doc "Starts a peer with an audio track and returns it with the track and a complete SDP offer."
  def offer do
    {:ok, pc} = PeerConnection.start_link(@options)
    track = MediaStreamTrack.new(:audio)
    {:ok, _sender} = PeerConnection.add_track(pc, track)
    {:ok, offer} = PeerConnection.create_offer(pc)
    :ok = PeerConnection.set_local_description(pc, offer)
    {pc, track, local_sdp(pc)}
  end

  @doc """
  Answers `offer` with a new peer that sends audio on its own track. Its messages go to `owner`, which can differ
  from the calling process.
  """
  def answer(offer, owner \\ self()) do
    {:ok, pc} = PeerConnection.start(@options)
    :ok = PeerConnection.set_remote_description(pc, %SessionDescription{type: :offer, sdp: offer})
    track = MediaStreamTrack.new(:audio)
    {:ok, _sender} = PeerConnection.add_track(pc, track)
    {:ok, answer} = PeerConnection.create_answer(pc)
    :ok = PeerConnection.set_local_description(pc, answer)
    sdp = local_sdp(pc)
    :ok = PeerConnection.controlling_process(pc, owner)
    {pc, track, sdp}
  end

  @doc "Applies the service's answer and waits until the peer is connected."
  def connect(pc, answer) do
    :ok = PeerConnection.set_remote_description(pc, %SessionDescription{type: :answer, sdp: answer})
    await_connected(pc)
  end

  def await_connected(pc) do
    assert_receive {:ex_webrtc, ^pc, {:connection_state_change, :connected}}, 5_000
    :ok
  end

  @doc "Sends an Opus RTP packet with `payload` on the track."
  def send_audio(pc, track, payload, sequence_number \\ 1) do
    packet = ExRTP.Packet.new(payload, sequence_number: sequence_number, timestamp: sequence_number * 960)
    PeerConnection.send_rtp(pc, track.id, packet)
  end

  defp local_sdp(pc) do
    assert_receive {:ex_webrtc, ^pc, {:ice_gathering_state_change, :complete}}, 5_000
    PeerConnection.get_local_description(pc).sdp
  end
end
