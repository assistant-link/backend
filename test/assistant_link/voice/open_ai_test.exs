defmodule AssistantLink.Voice.OpenAITest do
  # The test plays the session; a WebRTC peer behind Req.Test plays GPT-Live.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias AssistantLink.Assistants.Assistant
  alias AssistantLink.Calls.Call
  alias AssistantLink.Voice.OpenAI
  alias AssistantLink.WebRTCClient
  alias ExWebRTC.PeerConnection
  alias Plug.Conn

  @key "sk-test-not-a-real-key"

  defp start(config) do
    OpenAI.start_link(
      session: self(),
      call: %Call{id: Ecto.UUID.generate()},
      assistant: %Assistant{name: "Hermes"},
      instructions: "You are Hermes.",
      config: config,
      callers: [self()]
    )
  end

  defp config, do: [api_key: @key, req_options: [plug: {Req.Test, __MODULE__}]]

  defp stub_live_session(test) do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Conn.read_body(conn)
      %{"session" => session, "transport" => %{"type" => "webrtc", "sdp" => offer}} = Jason.decode!(body)

      send(
        test,
        {:live_session, conn.method, conn.request_path, Conn.get_req_header(conn, "authorization"), session}
      )

      {pc, track, answer} = WebRTCClient.answer(offer, test)
      send(test, {:live_peer, pc, track})

      conn
      |> Conn.put_status(201)
      |> Req.Test.json(%{session: %{id: "live_test"}, transport: %{type: "webrtc", sdp: answer}})
    end)
  end

  defp event(pc, channel, event), do: PeerConnection.send_data(pc, channel, Jason.encode!(event))

  describe "a started session" do
    setup do
      stub_live_session(self())
      {:ok, vendor} = start(config())
      assert_receive {:live_peer, pc, track}
      assert_receive {:ex_webrtc, ^pc, {:data_channel, %{label: "oai-events", ref: channel}}}, 5_000
      %{vendor: vendor, pc: pc, track: track, channel: channel}
    end

    test "creates a GPT-Live WebRTC session with the instructions" do
      assert_received {:live_session, "POST", "/v1/live/sessions", ["Bearer " <> @key], session}
      assert session == %{"model" => "gpt-live-1.1", "instructions" => "You are Hermes."}
    end

    test "relays audio both ways", %{vendor: vendor, pc: pc, track: track} do
      WebRTCClient.send_audio(pc, track, <<7, 7>>)
      assert_receive {:voice_vendor, ^vendor, {:audio, %ExRTP.Packet{payload: <<7, 7>>}}}, 5_000

      OpenAI.send_audio(vendor, ExRTP.Packet.new(<<8, 8>>, sequence_number: 1, timestamp: 960))
      assert_receive {:ex_webrtc, ^pc, {:rtp, _track_id, nil, %ExRTP.Packet{payload: <<8, 8>>}}}, 5_000
    end

    test "sends transcript deltas with their timing", %{vendor: vendor, pc: pc, channel: channel} do
      event(pc, channel, %{type: "session.started", session: %{id: "live_test"}})
      event(pc, channel, %{type: "session.input_transcript.delta", delta: "Hello", start_ms: 1000, end_ms: 1500})
      event(pc, channel, %{type: "session.output_transcript.delta", delta: "Hi there", start_ms: 2000, end_ms: 2600})

      assert_receive {:voice_vendor, ^vendor, {:transcript, :user, "Hello", started_at, ended_at}}, 5_000
      assert DateTime.diff(ended_at, started_at, :millisecond) == 500
      assert_receive {:voice_vendor, ^vendor, {:transcript, :assistant, "Hi there", assistant_at, _ended_at}}, 5_000
      assert DateTime.diff(assistant_at, started_at, :millisecond) == 1000
    end

    test "answers a delegation by itself", %{pc: pc, channel: channel} do
      event(pc, channel, %{
        type: "session.delegation.created",
        event_id: "event_1",
        delegation: %{id: "delegation_1", type: "delegation", target: "client"}
      })

      assert_receive {:ex_webrtc, ^pc, {:data, ^channel, data}}, 5_000

      assert %{"type" => "session.commentary.append", "delegation_id" => "delegation_1", "content" => content} =
               Jason.decode!(data)

      assert content =~ "can be looked up"
    end

    test "closes the session gracefully", %{vendor: vendor, pc: pc, channel: channel} do
      ref = Process.monitor(vendor)
      closing = Task.async(fn -> OpenAI.close(vendor) end)

      assert_receive {:ex_webrtc, ^pc, {:data, ^channel, data}}, 5_000
      assert %{"type" => "session.close"} = Jason.decode!(data)
      event(pc, channel, %{type: "session.closed", usage: %{seconds: 3}})

      assert Task.await(closing) == :ok
      assert_receive {:DOWN, ^ref, :process, ^vendor, :normal}
    end
  end

  test "is unavailable without an API key" do
    for key <- [nil, ""] do
      log = capture_log(fn -> assert start(api_key: key) == {:error, :voice_unavailable} end)
      assert log =~ "OPENAI_API_KEY is not set"
    end
  end

  test "is unavailable when OpenAI refuses the session, and logs no secret" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Conn.put_status(401)
      |> Req.Test.json(%{error: %{code: "invalid_api_key", message: "Incorrect API key provided: #{@key}"}})
    end)

    log = capture_log(fn -> assert start(config()) == {:error, :voice_unavailable} end)

    assert log =~ ~s{HTTP 401 ("invalid_api_key")}
    refute log =~ @key
    refute log =~ "a=fingerprint"
  end

  test "is unavailable when OpenAI answers an HTML page, and logs no body" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Conn.put_resp_content_type("text/html")
      |> Conn.send_resp(502, "<html><body>Bad Gateway from the proxy</body></html>")
    end)

    log = capture_log(fn -> assert start(config()) == {:error, :voice_unavailable} end)

    assert log =~ "HTTP 502 (nil)"
    refute log =~ "Bad Gateway"
    refute log =~ "BadMapError"
  end

  test "is unavailable when OpenAI answers an error string, and logs no body" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Conn.put_status(500)
      |> Req.Test.json(%{error: "upstream exploded for #{@key}"})
    end)

    log = capture_log(fn -> assert start(config()) == {:error, :voice_unavailable} end)

    assert log =~ "HTTP 500 (nil)"
    refute log =~ "upstream exploded"
    refute log =~ @key
    refute log =~ "BadMapError"
  end
end
