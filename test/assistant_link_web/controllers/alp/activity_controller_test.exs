defmodule AssistantLinkWeb.ALP.ActivityControllerTest do
  use AssistantLinkWeb.ConnCase, async: true

  import AssistantLink.LinksFixtures

  alias AssistantLink.Accounts
  alias AssistantLink.Links

  setup :register_device

  setup %{conn: conn, scope: scope, account: account} do
    {link, token} = paired_link_fixture(scope)
    :ok = Accounts.subscribe(account.id)
    %{conn: put_req_header(conn, "authorization", "Bearer " <> token), link: link}
  end

  defp put_activity(conn, params), do: conn |> put(~p"/alp/v1/link/activity", params) |> json_response(200)

  describe "PUT /alp/v1/link/activity while connected" do
    setup %{link: link} do
      :ok = Links.connect(link)
      link_id = link.id
      assert_receive {:link_status, %{link_id: ^link_id, status: :online}}
      :ok
    end

    test "sets the activity and tells the account's subscribers", %{conn: conn, link: link} do
      link_id = link.id

      assert put_activity(conn, %{"text" => "Searching the code…"}) == %{"activity" => "Searching the code…"}
      assert_receive {:link_activity, %{link_id: ^link_id, activity: "Searching the code…"}}
    end

    test "makes the text one trimmed line", %{conn: conn} do
      assert put_activity(conn, %{"text" => "  Reading\r\nthe\tlogs…\n"}) == %{"activity" => "Reading the logs…"}
    end

    test "keeps 60 code points and truncates longer text to 60 ending in …", %{conn: conn} do
      sixty = String.duplicate("é", 60)
      assert put_activity(conn, %{"text" => sixty}) == %{"activity" => sixty}

      assert put_activity(conn, %{"text" => String.duplicate("é", 61)}) ==
               %{"activity" => String.duplicate("é", 59) <> "…"}

      assert put_activity(conn, %{"text" => String.duplicate("a", 58) <> " bc"}) ==
               %{"activity" => String.duplicate("a", 58) <> "…"}
    end

    test "clears the activity for empty or blank text", %{conn: conn, link: link} do
      link_id = link.id

      for text <- ["", " \n "] do
        assert put_activity(conn, %{"text" => text}) == %{"activity" => nil}
        assert_receive {:link_activity, %{link_id: ^link_id, activity: nil}}
      end
    end
  end

  test "answers 409 not_connected without a connection, and still clears", %{conn: conn} do
    body = conn |> put(~p"/alp/v1/link/activity", %{"text" => "Thinking…"}) |> json_response(409)
    assert body["error"]["code"] == "not_connected"
    refute_received {:link_activity, _change}

    assert put_activity(conn, %{"text" => ""}) == %{"activity" => nil}
  end

  test "answers 422 invalid_params for a missing or non-string text", %{conn: conn} do
    for params <- [%{}, %{"text" => nil}, %{"text" => 1}] do
      body = conn |> put(~p"/alp/v1/link/activity", params) |> json_response(422)
      assert body["error"]["code"] == "invalid_params"
    end
  end

  test "DELETE clears the activity and answers 204", %{conn: conn, link: link} do
    link_id = link.id

    assert conn |> delete(~p"/alp/v1/link/activity") |> response(204)
    assert_receive {:link_activity, %{link_id: ^link_id, activity: nil}}
  end
end
