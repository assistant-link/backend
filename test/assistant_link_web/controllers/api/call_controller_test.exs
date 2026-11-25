defmodule AssistantLinkWeb.API.CallControllerTest do
  use AssistantLinkWeb.ConnCase, async: true

  import AssistantLink.LinksFixtures
  import Ecto.Query, only: [from: 2]

  alias AssistantLink.Accounts
  alias AssistantLink.Calls.Call
  alias AssistantLink.Events
  alias AssistantLink.Events.Event
  alias AssistantLink.Repo

  setup :register_device

  setup %{scope: scope, account: account} do
    {link, _token} = paired_link_fixture(scope)
    :ok = Accounts.subscribe(account.id)
    %{assistant: Repo.preload(link, :assistant).assistant}
  end

  defp start_call(conn, assistant_id, params \\ %{}),
    do: post(conn, ~p"/api/v1/assistants/#{assistant_id}/calls", params)

  defp end_call(conn, assistant_id, id), do: post(conn, ~p"/api/v1/assistants/#{assistant_id}/calls/#{id}/end")

  defp error_code(conn, status), do: json_response(conn, status)["error"]["code"]

  defp events(conn, assistant_id),
    do: conn |> get(~p"/api/v1/assistants/#{assistant_id}/events") |> json_response(200) |> Map.fetch!("events")

  defp voice_call(conn, assistant_id, call_id),
    do: conn |> events(assistant_id) |> Enum.find_value(&(&1["voice_call"]["call_id"] == call_id && &1["voice_call"]))

  defp age(call_id, minutes) do
    started_at = DateTime.shift(DateTime.utc_now(), minute: -minutes)
    Repo.update_all(from(c in Call, where: c.id == ^call_id), set: [started_at: started_at])
  end

  describe "POST /api/v1/assistants/:assistant_id/calls" do
    test "starts a realtime relay call with a voice_call and a call_started event",
         %{conn: conn, assistant: assistant} do
      assistant_id = assistant.id

      assert %{"call" => %{"id" => id, "started_at" => started_at} = call} =
               conn |> start_call(assistant.id) |> json_response(201)

      assert call == %{
               "id" => id,
               "assistant_id" => assistant_id,
               "mode" => "realtime_relay",
               "started_at" => started_at,
               "ended_at" => nil,
               "ended_by" => nil
             }

      assert [_link_created, voice_call, call_started] = events(conn, assistant.id)

      assert %{
               "type" => "voice_call",
               "sender" => "system",
               "voice_call" => %{
                 "call_id" => ^id,
                 "mode" => "realtime_relay",
                 "started_at" => ^started_at,
                 "ended_at" => nil,
                 "duration_seconds" => nil,
                 "transcript_url" => transcript_url
               }
             } = voice_call

      assert transcript_url == AssistantLinkWeb.Endpoint.url() <> "/alp/v1/calls/#{id}/transcript"
      refute Map.has_key?(voice_call, "delivery_status")
      assert %{"type" => "call_started", "sender" => "user"} = call_started

      assert_receive {:event_created, %Event{type: :voice_call}}
      assert_receive {:event_created, %Event{type: :call_started}}
      assert Events.on_call?(assistant.id)
    end

    test "takes a native mode and rejects an unknown one", %{conn: conn, assistant: assistant} do
      assert error_code(start_call(conn, assistant.id, %{"mode" => "phone"}), 422) == "invalid_params"
      assert conn |> start_call(assistant.id, %{"mode" => "native"}) |> json_response(201)
      assert [%Call{mode: :native}] = Repo.all(Call)
    end

    test "returns the open call while the Assistant has one", %{conn: conn, assistant: assistant} do
      %{"call" => call} = conn |> start_call(assistant.id) |> json_response(201)
      assert_receive {:event_created, %Event{type: :voice_call}}
      assert_receive {:event_created, %Event{type: :call_started}}
      events = events(conn, assistant.id)

      assert conn |> start_call(assistant.id) |> json_response(200) == %{"call" => call}
      assert conn |> start_call(assistant.id, %{"mode" => "native"}) |> json_response(200) == %{"call" => call}
      assert Repo.aggregate(Call, :count) == 1
      assert events(conn, assistant.id) == events
      refute_received {:event_created, _event}
      refute_received {:event_updated, _event}
    end

    test "ends an open call over an hour old as the system's and starts a new one",
         %{conn: conn, assistant: assistant} do
      old_id = conn |> start_call(assistant.id) |> json_response(201) |> get_in(["call", "id"])
      age(old_id, 61)

      new_id = conn |> start_call(assistant.id) |> json_response(201) |> get_in(["call", "id"])

      assert %Call{ended_by: :system, ended_at: %DateTime{}} = Repo.get!(Call, old_id)
      assert %Call{ended_at: nil} = Repo.get!(Call, new_id)
      assert_receive {:event_updated, %Event{type: :voice_call, call: %Call{id: ^old_id, ended_by: :system}}}
    end

    test "ends an abandoned call an hour after it started, not when the next call starts",
         %{conn: conn, assistant: assistant} do
      old_id = conn |> start_call(assistant.id) |> json_response(201) |> get_in(["call", "id"])
      age(old_id, 3 * 24 * 60)

      conn |> start_call(assistant.id) |> json_response(201)

      assert %{"duration_seconds" => 3600} = voice_call(conn, assistant.id, old_id)
    end

    test "ends an abandoned call at its last transcript entry", %{conn: conn, assistant: assistant} do
      old_id = conn |> start_call(assistant.id) |> json_response(201) |> get_in(["call", "id"])
      age(old_id, 3 * 24 * 60)
      %Call{started_at: started_at} = Repo.get!(Call, old_id)
      entries_path = ~p"/api/v1/assistants/#{assistant.id}/calls/#{old_id}/transcript_entries"

      for {offset, ended} <- [{10, 95}, {30, nil}] do
        params = %{
          "speaker" => "user",
          "text" => "Hi",
          "started_at" => DateTime.shift(started_at, second: offset),
          "ended_at" => ended && DateTime.shift(started_at, second: ended)
        }

        conn |> post(entries_path, params) |> json_response(201)
      end

      conn |> start_call(assistant.id) |> json_response(201)

      assert %{"duration_seconds" => 95} = voice_call(conn, assistant.id, old_id)
    end

    test "starts the call with the app's UUIDv7 id and returns it again for that id",
         %{conn: conn, assistant: assistant} do
      id = Ecto.UUID.generate(version: 7)

      assert %{"call" => %{"id" => ^id} = call} =
               conn |> start_call(assistant.id, %{"id" => id}) |> json_response(201)

      assert_receive {:event_created, %Event{type: :voice_call, call: %Call{id: ^id}}}
      assert_receive {:event_created, %Event{type: :call_started}}

      assert conn |> start_call(assistant.id, %{"id" => id}) |> json_response(200) == %{"call" => call}
      assert Repo.aggregate(Call, :count) == 1
      refute_received {:event_created, _event}
    end

    test "ends the open call as the system's and starts the app's new one when it sends another id",
         %{conn: conn, assistant: assistant} do
      old_id = conn |> start_call(assistant.id) |> json_response(201) |> get_in(["call", "id"])
      assert_receive {:event_created, %Event{type: :voice_call}}
      assert_receive {:event_created, %Event{type: :call_started}}
      id = Ecto.UUID.generate(version: 7)

      assert %{"call" => %{"id" => ^id, "ended_at" => nil}} =
               conn |> start_call(assistant.id, %{"id" => id}) |> json_response(201)

      assert %Call{ended_by: :system, ended_at: %DateTime{}} = Repo.get!(Call, old_id)
      assert [_link_created, _voice_call, _started, new_voice_call, call_started] = events(conn, assistant.id)
      assert %{"type" => "voice_call", "voice_call" => %{"call_id" => ^id}} = new_voice_call
      assert %{"type" => "call_started"} = call_started

      assert_receive {:event_updated, %Event{type: :voice_call, call: %Call{id: ^old_id, ended_by: :system}}}
      assert_receive {:event_created, %Event{type: :voice_call, call: %Call{id: ^id}}}
      assert_receive {:event_created, %Event{type: :call_started}}
      assert Events.on_call?(assistant.id)
    end

    test "the id of another call while one is open is 422 invalid_params and leaves it open",
         %{conn: conn, scope: scope, assistant: assistant} do
      {other, _token} = paired_link_fixture(scope, "Athena")
      other_id = conn |> start_call(other.assistant_id) |> json_response(201) |> get_in(["call", "id"])
      open_id = conn |> start_call(assistant.id) |> json_response(201) |> get_in(["call", "id"])

      assert error_code(start_call(conn, assistant.id, %{"id" => other_id}), 422) == "invalid_params"
      assert %Call{ended_at: nil} = Repo.get!(Call, open_id)
    end

    test "an ended call's id or another Assistant's is 422 invalid_params",
         %{conn: conn, scope: scope, assistant: assistant} do
      ended_id = conn |> start_call(assistant.id) |> json_response(201) |> get_in(["call", "id"])
      conn |> end_call(assistant.id, ended_id) |> json_response(200)

      {other, _token} = paired_link_fixture(scope, "Athena")
      other_id = conn |> start_call(other.assistant_id) |> json_response(201) |> get_in(["call", "id"])
      events = events(conn, assistant.id)

      for id <- [ended_id, other_id] do
        assert error_code(start_call(conn, assistant.id, %{"id" => id}), 422) == "invalid_params"
      end

      assert Repo.aggregate(Call, :count) == 2
      assert events(conn, assistant.id) == events
      refute Events.on_call?(assistant.id)
    end

    test "the id of an open call over an hour old is 422 invalid_params and leaves it open",
         %{conn: conn, assistant: assistant} do
      id = Ecto.UUID.generate(version: 7)
      conn |> start_call(assistant.id, %{"id" => id}) |> json_response(201)
      age(id, 61)

      assert error_code(start_call(conn, assistant.id, %{"id" => id}), 422) == "invalid_params"
      assert %Call{ended_at: nil} = Repo.get!(Call, id)
    end

    test "a malformed or non-UUIDv7 id is 422 invalid_params", %{conn: conn, assistant: assistant} do
      for id <- ["abc", Ecto.UUID.generate(version: 4), 7] do
        assert error_code(start_call(conn, assistant.id, %{"id" => id}), 422) == "invalid_params"
      end

      assert Repo.aggregate(Call, :count) == 0
    end

    test "another account's Assistant is 404", %{conn: conn} do
      {:ok, %{credential: credential}} = Accounts.register_device()
      {link, _token} = paired_link_fixture(Accounts.get_scope_by_device_token(credential))

      assert error_code(start_call(conn, link.assistant_id), 404) == "not_found"
    end
  end

  describe "GET /api/v1/assistants/:assistant_id/calls/:id" do
    test "shows the call", %{conn: conn, assistant: assistant} do
      %{"call" => call} = conn |> start_call(assistant.id) |> json_response(201)

      assert conn |> get(~p"/api/v1/assistants/#{assistant.id}/calls/#{call["id"]}") |> json_response(200) ==
               %{"call" => call}
    end

    test "an unknown call or another Assistant's is 404 call_not_found", %{
      conn: conn,
      scope: scope,
      assistant: assistant
    } do
      {other, _token} = paired_link_fixture(scope, "Athena")
      %{"call" => call} = conn |> start_call(other.assistant_id) |> json_response(201)

      for id <- [call["id"], Ecto.UUID.generate(), "abc"] do
        assert error_code(get(conn, ~p"/api/v1/assistants/#{assistant.id}/calls/#{id}"), 404) == "call_not_found"
      end
    end
  end

  describe "POST /api/v1/assistants/:assistant_id/calls/:id/end" do
    test "ends the call as the user's, updating the voice_call and storing call_ended",
         %{conn: conn, assistant: assistant} do
      %{"call" => %{"id" => id}} = conn |> start_call(assistant.id) |> json_response(201)
      age(id, 2)

      assert %{"call" => %{"id" => ^id, "ended_at" => ended_at, "ended_by" => "user"}} =
               conn |> end_call(assistant.id, id) |> json_response(200)

      assert {:ok, _ended_at, 0} = DateTime.from_iso8601(ended_at)
      refute Events.on_call?(assistant.id)

      assert [_link_created, voice_call, _started, call_ended] = events(conn, assistant.id)
      assert %{"ended_at" => ^ended_at, "duration_seconds" => duration} = voice_call["voice_call"]
      assert duration in 119..121
      assert %{"type" => "call_ended", "sender" => "user"} = call_ended

      assert_receive {:event_updated, %Event{type: :voice_call, call: %Call{id: ^id, ended_by: :user}}}
      assert_receive {:event_created, %Event{type: :call_ended, sender: :user}}
    end

    test "answers 409 call_already_ended for an ended call", %{conn: conn, assistant: assistant} do
      %{"call" => %{"id" => id}} = conn |> start_call(assistant.id) |> json_response(201)
      conn |> end_call(assistant.id, id) |> json_response(200)

      assert error_code(end_call(conn, assistant.id, id), 409) == "call_already_ended"
      assert Repo.aggregate(from(e in Event, where: e.type == :call_ended), :count) == 1
    end

    test "an unknown call is 404 call_not_found", %{conn: conn, assistant: assistant} do
      assert error_code(end_call(conn, assistant.id, Ecto.UUID.generate()), 404) == "call_not_found"
    end
  end
end
