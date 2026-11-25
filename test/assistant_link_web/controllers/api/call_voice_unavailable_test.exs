defmodule AssistantLinkWeb.API.CallVoiceUnavailableTest do
  # Selects the OpenAI vendor for the whole application.
  use AssistantLinkWeb.ConnCase, async: false

  import AssistantLink.LinksFixtures
  import ExUnit.CaptureLog

  alias AssistantLink.Repo
  alias AssistantLink.Voice
  alias AssistantLink.WebRTCClient

  setup :register_device

  setup %{conn: conn, scope: scope} do
    voice = Application.fetch_env!(:assistant_link, Voice)
    Application.put_env(:assistant_link, Voice, Keyword.put(voice, :vendor, Voice.OpenAI))
    on_exit(fn -> Application.put_env(:assistant_link, Voice, voice) end)

    {link, _token} = paired_link_fixture(scope)
    assistant = Repo.preload(link, :assistant).assistant
    call_id = conn |> post(~p"/api/v1/assistants/#{assistant.id}/calls") |> json_response(201) |> get_in(["call", "id"])
    %{assistant: assistant, call_id: call_id}
  end

  test "an offer gets voice_unavailable without an OpenAI key", %{conn: conn, assistant: assistant, call_id: call_id} do
    refute Application.get_env(:assistant_link, Voice.OpenAI)[:api_key]
    {_pc, _track, offer} = WebRTCClient.offer()

    log =
      capture_log(fn ->
        conn = post(conn, ~p"/api/v1/assistants/#{assistant.id}/calls/#{call_id}/webrtc", %{"offer" => offer})

        assert json_response(conn, 503) == %{
                 "error" => %{
                   "code" => "voice_unavailable",
                   "message" => "The voice chat could not start. Try again in a moment."
                 }
               }
      end)

    assert log =~ "OPENAI_API_KEY is not set"
    refute Voice.session(call_id)
  end
end
