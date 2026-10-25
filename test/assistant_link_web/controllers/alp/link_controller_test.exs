defmodule AssistantLinkWeb.ALP.LinkControllerTest do
  use AssistantLinkWeb.ConnCase, async: true

  import AssistantLink.LinksFixtures

  alias AssistantLink.Accounts
  alias AssistantLink.Events
  alias AssistantLink.Links
  alias AssistantLink.Repo

  setup :register_device

  setup %{conn: conn, scope: scope, account: account} do
    {link, token} = paired_link_fixture(scope)
    :ok = Accounts.subscribe(account.id)

    %{
      conn: put_req_header(conn, "authorization", "Bearer " <> token),
      link: link,
      assistant: Repo.preload(link, :assistant).assistant
    }
  end

  defp user_message(scope, assistant) do
    params = %{"text" => "Hi", "idempotency_key" => Ecto.UUID.generate(version: 7)}
    {:ok, event, :created} = Events.create_text_message(scope, assistant.id, params)
    event
  end

  describe "GET /alp/v1/link" do
    test "counts the user's messages after the cursor, not the link_created event", %{
      conn: conn,
      scope: scope,
      assistant: assistant,
      link: link
    } do
      for _message <- 1..3, do: user_message(scope, assistant)
      {:ok, _event, :created} = Events.create_assistant_message(link, %{"text" => "Done."})

      body = conn |> get(~p"/alp/v1/link") |> json_response(200)

      assert body == %{"link_id" => link.id, "assistant_name" => "Hermes", "unread_count" => 3}
    end

    test "counts from the Link's cursor", %{conn: conn, scope: scope, assistant: assistant, link: link} do
      first = user_message(scope, assistant)
      user_message(scope, assistant)
      :ok = Events.acknowledge(link.id, first.id)

      assert %{"unread_count" => 1} = conn |> get(~p"/alp/v1/link") |> json_response(200)
    end

    test "is 0 when nothing is waiting, and counts a deleted message", %{conn: conn, scope: scope, assistant: assistant} do
      assert %{"unread_count" => 0} = conn |> get(~p"/alp/v1/link") |> json_response(200)

      event = user_message(scope, assistant)
      Repo.delete!(Repo.get!(AssistantLink.Events.TextMessage, event.id))

      assert %{"unread_count" => 1} = conn |> get(~p"/alp/v1/link") |> json_response(200)
    end

    test "only counts: the cursor, presence, and last active time stay", %{
      conn: conn,
      scope: scope,
      assistant: assistant,
      link: link
    } do
      user_message(scope, assistant)
      before = Repo.reload!(link)

      for _request <- 1..2, do: conn |> get(~p"/alp/v1/link") |> json_response(200)

      assert Repo.reload!(link) == before
      assert Links.status(link) == :offline
      assert before.last_read_seq == 1
      assert before.last_active_at == nil
      refute_receive {:link_status, _change}
    end

    test "answers 401 for a missing or unknown token", %{conn: conn} do
      for header <- [nil, "Bearer alt_unknown"] do
        conn =
          if header, do: put_req_header(conn, "authorization", header), else: delete_req_header(conn, "authorization")

        assert conn |> get(~p"/alp/v1/link") |> json_response(401) |> get_in(["error", "code"]) == "unauthorized"
      end
    end

    test "answers 401 for the token of a deleted account", %{conn: conn, scope: scope} do
      :ok = Accounts.delete_account(scope)

      assert conn |> get(~p"/alp/v1/link") |> json_response(401) |> get_in(["error", "code"]) == "unauthorized"
    end
  end
end
