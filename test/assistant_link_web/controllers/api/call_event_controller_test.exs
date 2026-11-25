defmodule AssistantLinkWeb.API.CallEventControllerTest do
  use AssistantLinkWeb.ConnCase, async: true

  import AssistantLink.LinksFixtures
  import Ecto.Query, only: [from: 2]

  alias AssistantLink.Accounts
  alias AssistantLink.Calls.Call
  alias AssistantLink.Events
  alias AssistantLink.Events.Event
  alias AssistantLink.Repo

  setup :register_device

  setup %{scope: scope} do
    {link, _token} = paired_link_fixture(scope)
    %{assistant: Repo.preload(link, :assistant).assistant}
  end

  defp call_event(conn, assistant_id, params),
    do: post(conn, ~p"/api/v1/assistants/#{assistant_id}/call_events", params)

  defp params(type), do: %{"type" => type, "idempotency_key" => Ecto.UUID.generate(version: 7)}

  test "stores the call event as the user's event without content", %{conn: conn, assistant: assistant} do
    params = params("call_started")
    assistant_id = assistant.id
    key = params["idempotency_key"]

    assert %{
             "event" =>
               %{
                 "id" => id,
                 "assistant_id" => ^assistant_id,
                 "type" => "call_started",
                 "sender" => "user",
                 "deleted" => false,
                 "idempotency_key" => ^key
               } = event
           } = conn |> call_event(assistant.id, params) |> json_response(201)

    refute Map.has_key?(event, "call_started")
    assert %Event{seq: 3, sender: :user} = Repo.get!(Event, id)
  end

  test "a replay of the key returns the stored event with 200", %{conn: conn, assistant: assistant} do
    params = params("call_ended")
    first = conn |> call_event(assistant.id, params) |> json_response(201)
    replay = conn |> call_event(assistant.id, params) |> json_response(200)

    assert replay == first
    assert Repo.reload!(assistant).last_event_seq == 2
  end

  test "a key of a text message is a conflict", %{conn: conn, assistant: assistant} do
    key = Ecto.UUID.generate(version: 7)
    post(conn, ~p"/api/v1/assistants/#{assistant.id}/messages", %{"text" => "Hi", "idempotency_key" => key})

    conn = call_event(conn, assistant.id, %{"type" => "call_started", "idempotency_key" => key})
    assert json_response(conn, 409)["error"]["code"] == "idempotency_key_conflict"
  end

  test "a key of a call event is a conflict for a text message", %{conn: conn, assistant: assistant} do
    params = params("call_started")
    call_event(conn, assistant.id, params)

    conn = post(conn, ~p"/api/v1/assistants/#{assistant.id}/messages", Map.put(params, "text", "Hi"))
    assert json_response(conn, 409)["error"]["code"] == "idempotency_key_conflict"
  end

  test "a bad type is 422 invalid_params", %{conn: conn, assistant: assistant} do
    for type <- ["text_message", "call", nil] do
      conn = call_event(conn, assistant.id, params(type))
      assert json_response(conn, 422)["error"]["code"] == "invalid_params"
    end
  end

  test "another account's Assistant is 404", %{conn: conn} do
    {:ok, %{credential: credential}} = Accounts.register_device()
    other = Accounts.get_scope_by_device_token(credential)
    {link, _token} = paired_link_fixture(other)

    conn = call_event(conn, link.assistant_id, params("call_started"))
    assert json_response(conn, 404)["error"]["code"] == "not_found"
  end

  test "is listed with the Assistant's events", %{conn: conn, assistant: assistant} do
    call_event(conn, assistant.id, params("call_started"))

    events = conn |> get(~p"/api/v1/assistants/#{assistant.id}/events") |> json_response(200) |> Map.fetch!("events")
    assert Enum.map(events, & &1["type"]) == ["link_created", "voice_call", "call_started"]
  end

  describe "for an app that does not know calls" do
    test "call_started starts a call and call_ended ends it as the user's", %{conn: conn, assistant: assistant} do
      conn |> call_event(assistant.id, params("call_started")) |> json_response(201)

      assert [%Call{id: id, mode: :realtime_relay, ended_at: nil}] = Repo.all(Call)
      assert Events.on_call?(assistant.id)

      conn |> call_event(assistant.id, params("call_ended")) |> json_response(201)

      assert %Call{ended_by: :user, ended_at: %DateTime{}} = Repo.get!(Call, id)
      refute Events.on_call?(assistant.id)
    end

    test "a second call_started ends the open call as the system's", %{conn: conn, assistant: assistant} do
      call_event(conn, assistant.id, params("call_started"))
      call_event(conn, assistant.id, params("call_started"))

      assert [%Call{ended_by: :system}, %Call{ended_at: nil}] = Repo.all(from c in Call, order_by: c.started_at)
    end

    test "call_ended without a call stores only the event", %{conn: conn, assistant: assistant} do
      conn |> call_event(assistant.id, params("call_ended")) |> json_response(201)

      assert Repo.aggregate(Call, :count) == 0
    end

    test "a replayed call_started starts no other call", %{conn: conn, assistant: assistant} do
      params = params("call_started")
      call_event(conn, assistant.id, params)
      conn |> call_event(assistant.id, params) |> json_response(200)

      assert Repo.aggregate(Call, :count) == 1
    end

    test "call_ended ends a call the app started with the calls API", %{conn: conn, assistant: assistant} do
      %{"call" => %{"id" => id}} = conn |> post(~p"/api/v1/assistants/#{assistant.id}/calls") |> json_response(201)
      call_event(conn, assistant.id, params("call_ended"))

      assert %Call{ended_by: :user} = Repo.get!(Call, id)
    end
  end
end
