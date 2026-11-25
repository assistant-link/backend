defmodule AssistantLinkWeb.ALP.HangupControllerTest do
  use AssistantLinkWeb.ConnCase, async: true

  import AssistantLink.LinksFixtures
  import Ecto.Query, only: [from: 2]

  alias AssistantLink.Accounts
  alias AssistantLink.Calls.Call
  alias AssistantLink.Events
  alias AssistantLink.Events.Event
  alias AssistantLink.Links
  alias AssistantLink.Repo

  setup :register_device

  setup %{conn: conn, scope: scope, account: account} do
    {link, token} = paired_link_fixture(scope)
    :ok = Accounts.subscribe(account.id)
    %{conn: put_req_header(conn, "authorization", "Bearer " <> token), link: link}
  end

  defp key, do: Ecto.UUID.generate(version: 7)

  defp start_call(scope, link) do
    params = %{"type" => "call_started", "idempotency_key" => key()}
    {:ok, event, :created} = Events.create_call_event(scope, link.assistant_id, params)
    event
  end

  defp hang_up(conn, params \\ %{}), do: post(conn, ~p"/alp/v1/hangup", params)

  defp error_code(conn, status), do: json_response(conn, status)["error"]["code"]

  defp call_ended_count, do: Repo.aggregate(from(e in Event, where: e.type == :call_ended), :count)

  describe "POST /alp/v1/hangup" do
    test "stores call_ended as the Assistant's and answers 201, leaving the Link offline",
         %{conn: conn, scope: scope, link: link} do
      start_call(scope, link)

      conn = hang_up(conn)

      assert %{"event_id" => id, "created_at" => created_at} = body = json_response(conn, 201)
      assert body |> Map.keys() |> Enum.sort() == ["created_at", "event_id"]
      assert {:ok, _created_at, 0} = DateTime.from_iso8601(created_at)

      link_id = link.id
      assert %Event{type: :call_ended, sender: :assistant, link_id: ^link_id} = Repo.get!(Event, id)
      assert_receive {:event_created, %Event{id: ^id, type: :call_ended}}
      assert_receive {:event_updated, %Event{type: :voice_call, call: %Call{ended_by: :assistant}}}
      assert [%Call{ended_by: :assistant, ended_at: %DateTime{}}] = Repo.all(Call)
      refute Events.on_call?(link.assistant_id)
      assert Links.status(link) == :offline
      assert Repo.reload!(link).last_active_at == nil
    end

    test "ignores a type, so an agent cannot start a call", %{conn: conn, scope: scope, link: link} do
      start_call(scope, link)

      id = conn |> hang_up(%{"type" => "call_started"}) |> json_response(201) |> Map.fetch!("event_id")

      assert Repo.get!(Event, id).type == :call_ended
    end

    test "answers 409 not_on_call and stores nothing when there is no call", %{conn: conn, scope: scope, link: link} do
      assert error_code(hang_up(conn), 409) == "not_on_call"

      start_call(scope, link)
      conn |> hang_up() |> json_response(201)
      assert error_code(hang_up(conn, %{"idempotency_key" => key()}), 409) == "not_on_call"

      assert json_response(hang_up(conn), 409)["error"]["message"] == "The Assistant is not on a call."
      assert call_ended_count() == 1
    end

    test "answers 409 not_on_call for a call started over an hour old", %{conn: conn, scope: scope, link: link} do
      start_call(scope, link)
      Repo.update_all(Call, set: [started_at: DateTime.shift(DateTime.utc_now(), minute: -61)])

      assert error_code(hang_up(conn), 409) == "not_on_call"
      assert call_ended_count() == 0
    end

    test "answers 200 with the stored values for a repeated key, also after the call ended",
         %{conn: conn, scope: scope, link: link} do
      start_call(scope, link)
      params = %{"idempotency_key" => key()}
      first = conn |> hang_up(params) |> json_response(201)

      assert conn |> hang_up(params) |> json_response(200) == first
      assert call_ended_count() == 1
    end

    test "answers 409 idempotency_key_conflict for a key of another event",
         %{conn: conn, scope: scope, link: link} do
      {_other_link, other_token} = another_paired_link_fixture(scope, Repo.preload(link, :assistant).assistant)
      message_key = key()

      {:ok, _event, :created} =
        Events.create_assistant_message(link, %{"text" => "Hi", "idempotency_key" => message_key})

      start_call(scope, link)
      hangup_key = key()
      conn |> hang_up(%{"idempotency_key" => hangup_key}) |> json_response(201)
      start_call(scope, link)

      other = put_req_header(conn, "authorization", "Bearer " <> other_token)

      assert error_code(hang_up(conn, %{"idempotency_key" => message_key}), 409) == "idempotency_key_conflict"
      assert error_code(hang_up(other, %{"idempotency_key" => hangup_key}), 409) == "idempotency_key_conflict"
      assert call_ended_count() == 1
    end

    test "answers 422 invalid_params for a malformed key and stores nothing", %{conn: conn, scope: scope, link: link} do
      start_call(scope, link)

      for bad_key <- ["abc", Ecto.UUID.generate(), String.duplicate("a", 16), 5, ["x"]] do
        assert error_code(hang_up(conn, %{"idempotency_key" => bad_key}), 422) == "invalid_params"
      end

      assert call_ended_count() == 0
    end

    test "answers 401 for a missing, unknown, account, or deleted account's token",
         %{conn: conn, scope: scope, link: link, credential: credential} do
      start_call(scope, link)

      for header <- [nil, "Bearer alt_unknown", "Bearer " <> credential] do
        conn =
          if header, do: put_req_header(conn, "authorization", header), else: delete_req_header(conn, "authorization")

        assert error_code(hang_up(conn), 401) == "unauthorized"
      end

      :ok = Accounts.delete_account(scope)

      assert error_code(hang_up(conn), 401) == "unauthorized"
    end
  end
end
