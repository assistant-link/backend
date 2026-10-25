defmodule AssistantLinkWeb.ALP.LinkControllerTest do
  use AssistantLinkWeb.ConnCase, async: true

  import AssistantLink.LinksFixtures

  alias AssistantLink.Accounts
  alias AssistantLink.Events
  alias AssistantLink.Events.TextMessage
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

  defp unread_count(conn), do: conn |> get(~p"/alp/v1/link") |> json_response(200) |> Map.fetch!("unread_count")

  describe "GET /alp/v1/link" do
    test "counts the user's messages after the cursor, not the link_created event or the agent's own, and only counts",
         %{conn: conn, scope: scope, assistant: assistant, link: link} do
      for _message <- 1..3, do: user_message_fixture(scope, assistant)
      {:ok, _event, :created} = Events.create_assistant_message(link, %{"text" => "Done."})
      before = Repo.reload!(link)

      body = conn |> get(~p"/alp/v1/link") |> json_response(200)

      assert body == %{"link_id" => link.id, "assistant_name" => "Hermes", "unread_count" => 3}
      assert Repo.reload!(link) == before
      assert Links.status(link) == :offline
      refute_receive {:link_status, _change}
    end

    test "counts from the Link's cursor and a deleted message, and is 0 when nothing is waiting",
         %{conn: conn, scope: scope, assistant: assistant, link: link} do
      assert unread_count(conn) == 0

      first = user_message_fixture(scope, assistant)
      second = user_message_fixture(scope, assistant)
      :ok = Events.acknowledge(link.id, first.id)
      Repo.delete!(Repo.get!(TextMessage, second.id))

      assert unread_count(conn) == 1
    end

    test "answers 401 for a missing, unknown, or deleted account's token", %{conn: conn, scope: scope} do
      for header <- [nil, "Bearer alt_unknown"] do
        conn =
          if header, do: put_req_header(conn, "authorization", header), else: delete_req_header(conn, "authorization")

        assert conn |> get(~p"/alp/v1/link") |> json_response(401) |> get_in(["error", "code"]) == "unauthorized"
      end

      :ok = Accounts.delete_account(scope)

      assert conn |> get(~p"/alp/v1/link") |> json_response(401) |> get_in(["error", "code"]) == "unauthorized"
    end
  end
end
