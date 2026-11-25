defmodule AssistantLinkWeb.API.CallWebRTCTest do
  use AssistantLinkWeb.ConnCase, async: true

  import AssistantLink.LinksFixtures

  alias AssistantLink.Accounts
  alias AssistantLink.Calls.TranscriptEntry
  alias AssistantLink.Repo
  alias AssistantLink.Voice
  alias AssistantLink.Voice.FakeVendor
  alias AssistantLink.WebRTCClient

  setup :register_device

  setup %{conn: conn, scope: scope, account: account} do
    {link, _token} = paired_link_fixture(scope)
    assistant = Repo.preload(link, :assistant).assistant
    :ok = Accounts.subscribe(account.id)
    call_id = conn |> post(~p"/api/v1/assistants/#{assistant.id}/calls") |> json_response(201) |> get_in(["call", "id"])
    %{assistant: assistant, call_id: call_id}
  end

  defp webrtc(conn, assistant_id, call_id, body),
    do: post(conn, ~p"/api/v1/assistants/#{assistant_id}/calls/#{call_id}/webrtc", body)

  defp error_code(conn, status), do: json_response(conn, status)["error"]["code"]

  # Stops the session while the test still owns its database connection.
  defp stop_session(call_id) do
    pid = Voice.session(call_id)
    ref = Process.monitor(pid)
    :ok = Voice.stop(call_id)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
  end

  test "answers the app's offer and relays its audio through the voice agent",
       %{conn: conn, assistant: assistant, call_id: call_id} do
    {pc, track, offer} = WebRTCClient.offer()

    assert %{"answer" => answer} = conn |> webrtc(assistant.id, call_id, %{"offer" => offer}) |> json_response(200)
    assert answer =~ "a=candidate:"
    :ok = WebRTCClient.connect(pc, answer)

    WebRTCClient.send_audio(pc, track, <<1, 2, 3>>)
    assert_receive {:ex_webrtc, ^pc, {:rtp, _track_id, nil, %ExRTP.Packet{payload: <<1, 2, 3>>}}}, 5_000

    stop_session(call_id)
  end

  test "saves what the voice agent says and hears as live transcript entries",
       %{conn: conn, assistant: assistant, call_id: call_id} do
    {_pc, _track, offer} = WebRTCClient.offer()
    conn |> webrtc(assistant.id, call_id, %{"offer" => offer}) |> json_response(200)
    greeting = "Hi, this is #{assistant.name}."

    assert_receive {:call_transcript_entry,
                    %TranscriptEntry{seq: 1, speaker: :assistant, text: ^greeting, ended_at: nil}}

    assert_receive {:call_transcript_entry, %TranscriptEntry{seq: 1, text: ^greeting, ended_at: %DateTime{}}},
                   1_000

    FakeVendor.hear(call_id, "What's the")
    FakeVendor.hear(call_id, " weather?")

    assert_receive {:call_transcript_entry, %TranscriptEntry{seq: 2, speaker: :user, text: "What's the", id: id}}
    assert_receive {:call_transcript_entry, %TranscriptEntry{id: ^id, text: "What's the weather?", ended_at: nil}}
    assert_receive {:call_transcript_entry, %TranscriptEntry{id: ^id, ended_at: %DateTime{}}}, 1_000

    FakeVendor.hear(call_id, "Thanks")
    assert_receive {:call_transcript_entry, %TranscriptEntry{seq: 3, speaker: :user, text: "Thanks"}}

    stop_session(call_id)

    assert [
             %{"seq" => 1, "speaker" => "assistant", "text" => ^greeting},
             %{"seq" => 2, "speaker" => "user", "text" => "What's the weather?"},
             %{"seq" => 3, "speaker" => "user", "text" => "Thanks", "ended_at" => ended_at}
           ] =
             conn
             |> get(~p"/api/v1/assistants/#{assistant.id}/calls/#{call_id}/transcript")
             |> json_response(200)
             |> Map.fetch!("transcript_entries")

    assert ended_at, "a stopped session ends its open entries"
  end

  test "stops the session when the call ends", %{conn: conn, assistant: assistant, call_id: call_id} do
    {_pc, _track, offer} = WebRTCClient.offer()
    conn |> webrtc(assistant.id, call_id, %{"offer" => offer}) |> json_response(200)
    assert_receive {:call_transcript_entry, %TranscriptEntry{ended_at: %DateTime{}}}, 1_000
    ref = Process.monitor(Voice.session(call_id))

    conn |> post(~p"/api/v1/assistants/#{assistant.id}/calls/#{call_id}/end") |> json_response(200)

    assert_receive {:DOWN, ^ref, :process, _pid, :normal}
  end

  test "replaces the session on a new offer for the call", %{conn: conn, assistant: assistant, call_id: call_id} do
    {_pc, _track, offer} = WebRTCClient.offer()
    conn |> webrtc(assistant.id, call_id, %{"offer" => offer}) |> json_response(200)
    first = Voice.session(call_id)
    ref = Process.monitor(first)

    {pc, _track, offer} = WebRTCClient.offer()
    %{"answer" => answer} = conn |> webrtc(assistant.id, call_id, %{"offer" => offer}) |> json_response(200)

    assert_receive {:DOWN, ^ref, :process, ^first, _reason}
    refute Voice.session(call_id) in [nil, first]
    :ok = WebRTCClient.connect(pc, answer)

    stop_session(call_id)
  end

  test "rejects a call that has ended", %{conn: conn, assistant: assistant, call_id: call_id} do
    conn |> post(~p"/api/v1/assistants/#{assistant.id}/calls/#{call_id}/end") |> json_response(200)
    {_pc, _track, offer} = WebRTCClient.offer()

    assert error_code(webrtc(conn, assistant.id, call_id, %{"offer" => offer}), 409) == "call_already_ended"
    refute Voice.session(call_id)
  end

  test "rejects an unknown call or Assistant", %{conn: conn, assistant: assistant, scope: scope} do
    {_pc, _track, offer} = WebRTCClient.offer()
    other_call = Ecto.UUID.generate()

    assert error_code(webrtc(conn, assistant.id, other_call, %{"offer" => offer}), 404) == "call_not_found"
    assert error_code(webrtc(conn, assistant.id, "not-a-uuid", %{"offer" => offer}), 404) == "call_not_found"
    assert error_code(webrtc(conn, Ecto.UUID.generate(), other_call, %{"offer" => offer}), 404) == "not_found"

    {other_link, _token} = paired_link_fixture(scope)
    assert error_code(webrtc(conn, other_link.assistant_id, other_call, %{"offer" => offer}), 404) == "call_not_found"
  end

  test "rejects a missing or invalid offer", %{conn: conn, assistant: assistant, call_id: call_id} do
    no_audio = "v=0\r\no=- 1 0 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n"

    for body <- [%{}, %{"offer" => nil}, %{"offer" => 42}, %{"offer" => "hello"}, %{"offer" => no_audio}] do
      assert error_code(webrtc(conn, assistant.id, call_id, body), 422) == "invalid_params"
    end

    refute Voice.session(call_id)
  end
end
