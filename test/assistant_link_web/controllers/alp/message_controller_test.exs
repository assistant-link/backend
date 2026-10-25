defmodule AssistantLinkWeb.ALP.MessageControllerTest do
  use AssistantLinkWeb.ConnCase, async: true

  import AssistantLink.LinksFixtures

  alias AssistantLink.Accounts
  alias AssistantLink.Events.Event
  alias AssistantLink.Events.TextMessage
  alias AssistantLink.Links
  alias AssistantLink.Repo

  setup :register_device

  setup %{conn: conn, scope: scope, account: account} do
    {link, token} = paired_link_fixture(scope)
    :ok = Accounts.subscribe(account.id)
    %{conn: put_req_header(conn, "authorization", "Bearer " <> token), link: link, token: token}
  end

  defp key, do: Ecto.UUID.generate(version: 7)

  defp post_message(conn, params), do: post(conn, ~p"/alp/v1/messages", params)

  defp error_code(conn, status), do: json_response(conn, status)["error"]["code"]

  defp stored_count, do: Repo.aggregate(TextMessage, :count)

  describe "POST /alp/v1/messages" do
    test "stores the message as the Assistant's and answers 201", %{conn: conn, link: link} do
      conn = post_message(conn, %{"text" => "Your reminder is set.", "idempotency_key" => key()})

      assert %{"message_id" => id, "created_at" => created_at} = body = json_response(conn, 201)
      assert body |> Map.keys() |> Enum.sort() == ["created_at", "message_id"]
      assert {:ok, _created_at, 0} = DateTime.from_iso8601(created_at)

      link_id = link.id

      assert %Event{type: :text_message, sender: :assistant, link_id: ^link_id, delivered_at: nil} =
               Repo.get!(Event, id)

      assert Repo.get!(TextMessage, id).text == "Your reminder is set."
      assert_receive {:event_created, %Event{id: ^id, sender: :assistant}}
    end

    test "works without an idempotency key", %{conn: conn} do
      ids =
        for _message <- 1..2,
            do: conn |> post_message(%{"text" => "Hi"}) |> json_response(201) |> Map.fetch!("message_id")

      assert [_first, _second] = Enum.uniq(ids)
      assert stored_count() == 2
    end

    test "leaves the Link offline and does not change presence or last active time", %{conn: conn, link: link} do
      conn = post_message(conn, %{"text" => "Hi", "idempotency_key" => key()})

      assert json_response(conn, 201)
      assert Links.status(link) == :offline
      assert Repo.reload!(link).last_active_at == nil
      refute_receive {:link_status, _change}
    end

    test "answers 200 with the stored values for a repeated key and stores one message", %{conn: conn} do
      params = %{"text" => "Hi", "idempotency_key" => key()}
      first = conn |> post_message(params) |> json_response(201)

      second = conn |> post_message(params) |> json_response(200)

      assert second == first
      assert stored_count() == 1
    end

    test "answers 200 for a repeated key even when the message was deleted", %{conn: conn} do
      params = %{"text" => "Hi", "idempotency_key" => key()}
      first = conn |> post_message(params) |> json_response(201)
      Repo.delete!(Repo.get!(TextMessage, first["message_id"]))

      assert conn |> post_message(params) |> json_response(200) == first
    end

    test "answers 409 for a key reused with another text", %{conn: conn} do
      key = key()
      conn |> post_message(%{"text" => "Hi", "idempotency_key" => key}) |> json_response(201)

      conn = post_message(conn, %{"text" => "Bye", "idempotency_key" => key})

      assert error_code(conn, 409) == "idempotency_key_conflict"
      assert stored_count() == 1
    end

    test "answers 409 for a key of another Link's message", %{conn: conn, scope: scope} do
      {_other_link, other_token} = paired_link_fixture(scope, "Muse")
      key = key()
      conn |> post_message(%{"text" => "Hi", "idempotency_key" => key}) |> json_response(201)

      other =
        conn
        |> put_req_header("authorization", "Bearer " <> other_token)
        |> post_message(%{"text" => "Hi", "idempotency_key" => key})

      assert error_code(other, 409) == "idempotency_key_conflict"
    end

    test "answers 422 invalid_params for a malformed key and stores nothing", %{conn: conn} do
      for bad_key <- ["abc", Ecto.UUID.generate(), String.duplicate("a", 16), 5, ["x"]] do
        conn = post_message(conn, %{"text" => "Hi", "idempotency_key" => bad_key})
        assert error_code(conn, 422) == "invalid_params"
      end

      assert stored_count() == 0
    end

    test "answers 422 for a bad text and stores nothing", %{conn: conn} do
      cases = [
        {"", "text_empty"},
        {"  \n", "text_empty"},
        {String.duplicate("😀", 4001), "text_too_long"},
        {"a\u0000b", "invalid_params"},
        {nil, "invalid_params"},
        {5, "invalid_params"}
      ]

      for {text, code} <- cases do
        conn = post_message(conn, %{"text" => text, "idempotency_key" => key()})
        assert error_code(conn, 422) == code
      end

      assert json_response(post_message(conn, %{"idempotency_key" => key()}), 422)
      assert stored_count() == 0
    end

    test "accepts 4,000 code points", %{conn: conn} do
      assert json_response(post_message(conn, %{"text" => String.duplicate("😀", 4000)}), 201)
    end

    test "answers 401 for a missing, unknown, or account token", %{conn: conn, credential: credential} do
      for header <- [nil, "Bearer alt_unknown", "Bearer " <> credential] do
        conn =
          if header, do: put_req_header(conn, "authorization", header), else: delete_req_header(conn, "authorization")

        assert error_code(post_message(conn, %{"text" => "Hi"}), 401) == "unauthorized"
      end

      assert stored_count() == 0
    end

    test "answers 401 for the token of a deleted account", %{conn: conn, scope: scope} do
      :ok = Accounts.delete_account(scope)

      assert error_code(post_message(conn, %{"text" => "Hi"}), 401) == "unauthorized"
      assert stored_count() == 0
    end
  end
end
