defmodule AssistantLinkWeb.API.WakeControllerTest do
  use AssistantLinkWeb.ConnCase, async: true

  import AssistantLink.LinksFixtures
  import Ecto.Query, only: [from: 2]

  alias AssistantLink.Accounts
  alias AssistantLink.Links
  alias AssistantLink.Links.Link
  alias AssistantLink.Repo

  setup :register_device

  setup do
    test = self()

    Req.Test.stub(AssistantLinkWeb.Webhook, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:webhook, conn.request_path, body})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    :ok
  end

  defp webhook_link(scope, name, path) do
    {link, _token} = paired_link_fixture(scope, name)
    {:ok, link} = Links.put_webhook(link, %{"url" => "https://a.test" <> path})
    link
  end

  test "is 401 without a credential" do
    conn = post(build_conn(), ~p"/api/v1/wake")
    assert json_response(conn, 401)
  end

  test "is 204 when there is no Link to ping", %{conn: conn} do
    assert conn |> post(~p"/api/v1/wake") |> response(204) == ""
    refute_receive {:webhook, _path, _json}
  end

  test "pings offline Links on different Assistants with the bare wake body", %{conn: conn, scope: scope} do
    first = webhook_link(scope, "First", "/first")
    second = webhook_link(scope, "Second", "/second")

    assert conn |> post(~p"/api/v1/wake") |> response(204)

    assert_receive {:webhook, "/first", json}, 1000
    assert Jason.decode!(json) == %{"type" => "wake", "link_id" => first.id}
    assert_receive {:webhook, "/second", json}, 1000
    assert Jason.decode!(json) == %{"type" => "wake", "link_id" => second.id}
  end

  test "skips online, unpaired and webhook-less Links", %{conn: conn, scope: scope} do
    online = webhook_link(scope, "Online", "/online")
    :ok = Links.connect(online)

    {:ok, assistant} = AssistantLink.Assistants.create_assistant(scope, %{"name" => "Idle", "avatar" => "avatar-1"})
    {:ok, unpaired} = Links.create_link(scope, assistant.id, %{})
    {:ok, _link} = Links.put_webhook(unpaired, %{"url" => "https://a.test/unpaired"})

    {bare, _token} = paired_link_fixture(scope, "Bare")
    assert bare.webhook_url == nil

    conn |> post(~p"/api/v1/wake") |> response(204)
    refute_receive {:webhook, _path, _json}
  end

  test "skips the Links of other accounts", %{conn: conn} do
    {:ok, %{credential: credential}} = Accounts.register_device()
    other = Accounts.get_scope_by_device_token(credential)
    webhook_link(other, "Theirs", "/theirs")

    conn |> post(~p"/api/v1/wake") |> response(204)
    refute_receive {:webhook, _path, _json}
  end

  test "skips a Link pinged less than 30 seconds ago and pings it again after", %{conn: conn, scope: scope} do
    link = webhook_link(scope, "Hermes", "/hook")

    post(conn, ~p"/api/v1/wake")
    assert_receive {:webhook, "/hook", _json}, 1000
    post(conn, ~p"/api/v1/wake")
    refute_receive {:webhook, _path, _json}

    past = DateTime.shift(DateTime.utc_now(), second: -31)
    Repo.update_all(from(l in Link, where: l.id == ^link.id), set: [webhook_pinged_at: past])
    post(conn, ~p"/api/v1/wake")
    assert_receive {:webhook, "/hook", _json}, 1000
  end
end
