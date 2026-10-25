defmodule AssistantLinkWeb.API.MessageControllerTest do
  use AssistantLinkWeb.ConnCase, async: true

  import AssistantLink.LinksFixtures

  alias AssistantLink.Assistants
  alias AssistantLink.Events.Event
  alias AssistantLink.Events.TextMessage
  alias AssistantLink.Links
  alias AssistantLink.Repo

  setup :register_device

  setup %{scope: scope} do
    {link, _token} = paired_link_fixture(scope)
    {:ok, unpaired} = Assistants.create_assistant(scope, %{"name" => "Muse", "avatar" => "avatar-2"})
    {:ok, _link} = Links.create_link(scope, unpaired.id, %{})

    %{assistant: Repo.preload(link, :assistant).assistant, unpaired: unpaired}
  end

  defp key, do: Ecto.UUID.generate(version: 7)

  defp send_message(conn, assistant, params), do: post(conn, ~p"/api/v1/assistants/#{assistant}/messages", params)

  defp send_text(conn, assistant, text),
    do: send_message(conn, assistant.id, %{"text" => text, "idempotency_key" => key()})

  defp error_code(conn, status), do: json_response(conn, status)["error"]["code"]

  describe "POST /api/v1/assistants/:assistant_id/messages" do
    test "stores the message as the user's event", %{conn: conn, assistant: assistant} do
      key = key()
      conn = send_message(conn, assistant.id, %{"text" => "Hi", "idempotency_key" => key})
      assistant_id = assistant.id

      assert %{
               "message" => %{
                 "id" => id,
                 "assistant_id" => ^assistant_id,
                 "type" => "text_message",
                 "sender" => "user",
                 "link_id" => nil,
                 "created_at" => created_at,
                 "deleted" => false,
                 "delivery_status" => "sent",
                 "idempotency_key" => ^key,
                 "text_message" => %{"text" => "Hi"}
               }
             } = json_response(conn, 201)

      assert {:ok, _created_at, 0} = DateTime.from_iso8601(created_at)
      assert %Event{seq: 2} = Repo.get!(Event, id)
    end

    test "stores nothing for an Assistant with no paired Link", %{conn: conn, unpaired: unpaired} do
      assert error_code(send_text(conn, unpaired, "Hi"), 422) == "no_paired_link"

      assert Repo.aggregate(TextMessage, :count) == 0
      assert Repo.reload!(unpaired).last_event_seq == 1
    end
  end

  describe "text" do
    test "rejects an empty text or one of only White_Space", %{conn: conn, assistant: assistant} do
      for text <- ["", " ", "\n\t", "  　\u0085"] do
        assert error_code(send_text(conn, assistant, text), 422) == "text_empty"
      end
    end

    test "counts Unicode code points, not graphemes or bytes", %{conn: conn, assistant: assistant} do
      assert json_response(send_text(conn, assistant, String.duplicate("😀", 4000)), 201)
      assert error_code(send_text(conn, assistant, String.duplicate("😀", 4001)), 422) == "text_too_long"

      # One grapheme of five code points
      assert error_code(send_text(conn, assistant, String.duplicate("👩‍👩‍👧", 801)), 422) == "text_too_long"
    end

    test "rejects U+0000 and a text that is not a string", %{conn: conn, assistant: assistant} do
      for text <- ["a\u0000b", "\u0000", nil, 5, ["Hi"]] do
        assert error_code(send_text(conn, assistant, text), 422) == "invalid_params"
      end
    end

    test "keeps text that only looks empty and surrounding whitespace", %{conn: conn, assistant: assistant} do
      for text <- ["​", "  Hi  ", "a\nb"] do
        assert json_response(send_text(conn, assistant, text), 201)["message"]["text_message"]["text"] == text
      end
    end
  end

  describe "idempotency_key" do
    test "is required and a UUIDv7", %{conn: conn, assistant: assistant} do
      for key <- [nil, "", "key", Ecto.UUID.generate(), 7] do
        conn = send_message(conn, assistant.id, %{"text" => "Hi", "idempotency_key" => key})
        assert error_code(conn, 422) == "invalid_params"
      end

      conn = send_message(conn, assistant.id, %{"text" => "Hi"})
      assert error_code(conn, 422) == "invalid_params"
      assert Repo.aggregate(TextMessage, :count) == 0
    end

    test "a repeat returns the stored event with 200 and stores nothing", %{conn: conn, assistant: assistant} do
      params = %{"text" => "Hi", "idempotency_key" => key()}
      first = conn |> send_message(assistant.id, params) |> json_response(201)
      repeat = conn |> send_message(assistant.id, params) |> json_response(200)

      assert repeat == first
      assert Repo.aggregate(TextMessage, :count) == 1
      assert Repo.reload!(assistant).last_event_seq == 2
    end

    test "a repeat returns the stored event even when its text was deleted", %{conn: conn, assistant: assistant} do
      params = %{"text" => "Hi", "idempotency_key" => key()}
      %{"message" => %{"id" => id}} = conn |> send_message(assistant.id, params) |> json_response(201)
      Repo.delete!(Repo.get!(TextMessage, id))

      assert %{"message" => %{"id" => ^id, "deleted" => true} = message} =
               conn |> send_message(assistant.id, params) |> json_response(200)

      refute Map.has_key?(message, "text_message")
    end

    test "a different text gets 409", %{conn: conn, assistant: assistant} do
      key = key()
      send_message(conn, assistant.id, %{"text" => "Hi", "idempotency_key" => key})

      conn = send_message(conn, assistant.id, %{"text" => "Bye", "idempotency_key" => key})

      assert error_code(conn, 409) == "idempotency_key_conflict"
      assert Repo.aggregate(TextMessage, :count) == 1
    end

    test "a different Assistant gets 409", %{conn: conn, scope: scope, assistant: assistant} do
      {other_link, _token} = paired_link_fixture(scope, "Grok")
      key = key()
      send_message(conn, assistant.id, %{"text" => "Hi", "idempotency_key" => key})

      conn = send_message(conn, other_link.assistant_id, %{"text" => "Hi", "idempotency_key" => key})

      assert error_code(conn, 409) == "idempotency_key_conflict"
    end

    test "is unique per account", %{conn: conn, assistant: assistant} do
      other = register_device(%{conn: build_conn()})
      {link, _token} = paired_link_fixture(other.scope)
      params = %{"text" => "Hi", "idempotency_key" => key()}
      send_message(conn, assistant.id, params)

      assert json_response(send_message(other.conn, link.assistant_id, params), 201)
    end
  end

  describe "check order" do
    test "404 comes before a bad text", %{conn: conn} do
      assert error_code(send_message(conn, Ecto.UUID.generate(), %{"text" => ""}), 404) == "not_found"
    end

    test "a stored key comes before a bad text", %{conn: conn, assistant: assistant} do
      key = key()
      send_message(conn, assistant.id, %{"text" => "Hi", "idempotency_key" => key})

      conn = send_message(conn, assistant.id, %{"text" => "", "idempotency_key" => key})
      assert error_code(conn, 409) == "idempotency_key_conflict"
    end

    test "a bad text or key comes before no_paired_link", %{conn: conn, unpaired: unpaired} do
      assert error_code(send_text(conn, unpaired, ""), 422) == "text_empty"

      conn = send_message(conn, unpaired.id, %{"text" => "Hi", "idempotency_key" => "key"})
      assert error_code(conn, 422) == "invalid_params"
    end
  end
end
