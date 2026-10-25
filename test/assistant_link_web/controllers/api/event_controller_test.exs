defmodule AssistantLinkWeb.API.EventControllerTest do
  use AssistantLinkWeb.ConnCase, async: true

  import AssistantLink.LinksFixtures

  alias AssistantLink.Events.TextMessage
  alias AssistantLink.Repo

  setup :register_device

  setup %{scope: scope} do
    {link, _token} = paired_link_fixture(scope)
    %{link: link, assistant: Repo.preload(link, :assistant).assistant}
  end

  defp send_texts(conn, assistant, texts) do
    for text <- texts do
      params = %{"text" => text, "idempotency_key" => Ecto.UUID.generate(version: 7)}
      conn |> post(~p"/api/v1/assistants/#{assistant}/messages", params) |> json_response(201)
    end
  end

  defp list(conn, assistant_id, params \\ %{}), do: get(conn, ~p"/api/v1/assistants/#{assistant_id}/events", params)

  describe "GET /api/v1/assistants/:assistant_id/events" do
    test "lists the events, oldest first, starting with link_created", %{conn: conn, assistant: assistant, link: link} do
      send_texts(conn, assistant, ["a", "b"])

      assert %{"events" => [created, first, second], "has_more" => false} = json_response(list(conn, assistant.id), 200)

      link_id = link.id

      assert %{"type" => "link_created", "sender" => "system", "link_id" => ^link_id, "deleted" => false} = created
      assert %{"idempotency_key" => nil} = created
      refute Map.has_key?(created, "delivery_status")
      refute Map.has_key?(created, "link_created")

      assert %{"text_message" => %{"text" => "a"}, "delivery_status" => "sent"} = first
      assert %{"text_message" => %{"text" => "b"}} = second
    end

    test "pages backwards with limit and before", %{conn: conn, assistant: assistant} do
      events = conn |> send_texts(assistant, ["a", "b", "c", "d"]) |> Enum.map(& &1["message"]["id"])
      page = fn params -> json_response(list(conn, assistant.id, params), 200) end
      ids = &Enum.map(&1["events"], fn event -> event["id"] end)

      assert %{"has_more" => true} = latest = page.(%{"limit" => "2"})
      assert ids.(latest) == Enum.slice(events, 2, 2)

      assert %{"has_more" => true} = earlier = page.(%{"limit" => "2", "before" => Enum.at(events, 2)})
      assert ids.(earlier) == Enum.take(events, 2)

      assert %{"has_more" => false, "events" => [%{"type" => "link_created"}]} = page.(%{"before" => hd(events)})
      assert %{"has_more" => false, "events" => [_, _, _]} = page.(%{"limit" => "3", "before" => Enum.at(events, 2)})
    end

    test "shows delivery and a deleted payload", %{conn: conn, scope: scope, assistant: assistant} do
      [%{"message" => delivered}, %{"message" => deleted}] = send_texts(conn, assistant, ["a", "b"])
      :ok = AssistantLink.Events.mark_delivered(scope.account.id, delivered["id"])
      Repo.delete!(Repo.get!(TextMessage, deleted["id"]))

      assert %{"events" => [_created, first, second]} = json_response(list(conn, assistant.id), 200)

      assert %{"delivery_status" => "delivered", "deleted" => false} = first
      assert %{"delivery_status" => "sent", "deleted" => true, "type" => "text_message"} = second
      refute Map.has_key?(second, "text_message")
    end

    test "rejects a bad before or limit with 422", %{conn: conn, assistant: assistant, scope: scope} do
      {other_link, _token} = paired_link_fixture(scope, "Grok")
      %{"events" => [%{"id" => other_event_id}]} = json_response(list(conn, other_link.assistant_id), 200)

      for params <- [
            %{"before" => Ecto.UUID.generate()},
            %{"before" => "x"},
            %{"before" => other_event_id},
            %{"limit" => "0"},
            %{"limit" => "101"},
            %{"limit" => "ten"}
          ] do
        conn = list(conn, assistant.id, params)
        assert json_response(conn, 422)["error"]["code"] == "invalid_params"
      end
    end

    test "answers 404 for an unknown id or another account's Assistant", %{conn: conn, assistant: assistant} do
      other = register_device(%{conn: build_conn()})

      for {conn, id} <- [{conn, Ecto.UUID.generate()}, {conn, "not-a-uuid"}, {other.conn, assistant.id}] do
        assert json_response(list(conn, id), 404)["error"]["code"] == "not_found"
      end
    end

    test "requires an account credential", %{assistant: assistant} do
      assert json_response(list(build_conn(), assistant.id), 401)["error"]["code"] == "unauthorized"
    end
  end
end
