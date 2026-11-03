defmodule AssistantLinkWeb.WebhookTest do
  use AssistantLinkWeb.ConnCase, async: true

  import AssistantLink.LinksFixtures
  import ExUnit.CaptureLog

  alias AssistantLink.Events
  alias AssistantLink.Links
  alias AssistantLink.Repo
  alias AssistantLinkWeb.API.EventJSON

  setup :register_device

  setup %{scope: scope} do
    {link, _token} = paired_link_fixture(scope)
    {:ok, link} = Links.put_webhook(link, %{"url" => "https://a.test/hook", "authorization" => "Bearer secret"})
    test = self()

    Req.Test.stub(AssistantLinkWeb.Webhook, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:webhook, conn.request_path, Plug.Conn.get_req_header(conn, "authorization"), body})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    %{link: link, assistant: Repo.preload(link, :assistant).assistant}
  end

  defp post_message(conn, assistant, params \\ %{}) do
    params = Map.merge(%{"text" => "Hi", "idempotency_key" => Ecto.UUID.generate(version: 7)}, params)
    post(conn, ~p"/api/v1/assistants/#{assistant.id}/messages", params)
  end

  test "posts the delivery event to the webhook of a paired Link", %{conn: conn, assistant: assistant} do
    body = conn |> post_message(assistant) |> json_response(201)

    assert_receive {:webhook, "/hook", ["Bearer secret"], json}, 1000
    assert Jason.decode!(json) == Jason.decode!(Jason.encode!(delivery(body["message"]["id"])))
  end

  test "sends no authorization header when none is set", %{conn: conn, link: link, assistant: assistant} do
    {:ok, _link} = Links.put_webhook(link, %{"url" => "https://a.test/hook"})
    post_message(conn, assistant)
    assert_receive {:webhook, "/hook", [], _json}, 1000
  end

  test "retries a 500 and then succeeds", %{conn: conn, assistant: assistant} do
    test = self()

    Req.Test.expect(AssistantLinkWeb.Webhook, fn conn ->
      send(test, :attempt)
      Plug.Conn.send_resp(conn, 500, "")
    end)

    post_message(conn, assistant)
    assert_receive :attempt, 1000
    assert_receive {:webhook, "/hook", _auth, _json}, 1000
  end

  test "does not post for a replay, an assistant message, or links without a webhook",
       %{conn: conn, scope: scope, link: link, assistant: assistant} do
    key = Ecto.UUID.generate(version: 7)
    post_message(conn, assistant, %{"idempotency_key" => key})
    assert_receive {:webhook, _path, _auth, _json}, 1000
    post_message(conn, assistant, %{"idempotency_key" => key})
    {:ok, _event, :created} = Events.create_assistant_message(link, %{"text" => "Done."})

    {other, _token} = paired_link_fixture(scope, "Other")
    {:ok, _link} = Links.delete_webhook(other)
    post_message(conn, Repo.preload(other, :assistant).assistant)

    refute_receive {:webhook, _path, _auth, _json}
  end

  test "does not post for an unpaired Link", %{conn: conn, scope: scope, assistant: assistant} do
    {:ok, unpaired} = Links.create_link(scope, assistant.id, %{})

    {:ok, _link} = Links.put_webhook(unpaired, %{"url" => "https://u.test/x"})
    post_message(conn, assistant)
    assert_receive {:webhook, "/hook", _auth, _json}, 1000
    refute_receive {:webhook, "/x", _auth, _json}
  end

  test "posts to every paired Link with a webhook", %{conn: conn, assistant: assistant, scope: scope} do
    {second, _token} = another_paired_link_fixture(scope, assistant)
    {:ok, _link} = Links.put_webhook(second, %{"url" => "https://b.test/second"})

    post_message(conn, assistant)

    assert_receive {:webhook, "/hook", _auth, _json}, 1000
    assert_receive {:webhook, "/second", _auth, _json}, 1000
  end

  test "logs a failure without the authorization when the request raises",
       %{conn: conn, link: link, assistant: assistant} do
    Req.Test.stub(AssistantLinkWeb.Webhook, fn _conn -> raise "boom" end)

    log =
      capture_log(fn ->
        post_message(conn, assistant)
        await_webhooks()
      end)

    assert log =~ "Webhook of Link #{link.id} failed"
    refute log =~ "[error]"
  end

  defp await_webhooks do
    refs = for pid <- Task.Supervisor.children(AssistantLinkWeb.Webhook.Supervisor), do: Process.monitor(pid)
    for ref <- refs, do: assert_receive({:DOWN, ^ref, :process, _pid, _reason}, 5000)
  end

  defp delivery(event_id) do
    AssistantLink.Events.Event |> Repo.get!(event_id) |> Repo.preload(:text_message) |> EventJSON.delivery()
  end
end
