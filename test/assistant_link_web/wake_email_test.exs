defmodule AssistantLinkWeb.WakeEmailTest do
  use AssistantLinkWeb.ConnCase, async: true

  import AssistantLink.LinksFixtures
  import Ecto.Query, only: [from: 2]

  alias AssistantLink.Links
  alias AssistantLink.Links.Link
  alias AssistantLink.Repo

  setup :register_device

  setup %{scope: scope} do
    {link, _token} = paired_link_fixture(scope)
    {:ok, link} = Links.put_wake_email(link, %{"address" => "hermes@example.com"})
    {:ok, link} = Links.confirm_wake_email(link.id, "hermes@example.com")
    test = self()

    Req.Test.stub(AssistantLinkWeb.Webhook, fn conn ->
      send(test, {:webhook, conn.request_path})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    %{link: link, assistant: Repo.preload(link, :assistant).assistant}
  end

  defp post_message(conn, assistant, text \\ "Hi") do
    params = %{"text" => text, "idempotency_key" => Ecto.UUID.generate(version: 7)}
    post(conn, ~p"/api/v1/assistants/#{assistant.id}/messages", params)
  end

  defp post_call_event(conn, assistant, type) do
    params = %{"type" => type, "idempotency_key" => Ecto.UUID.generate(version: 7)}
    post(conn, ~p"/api/v1/assistants/#{assistant.id}/call_events", params)
  end

  defp assert_minimal(body) do
    refute body =~ ~r/\bal(-\w+)? (send|read|call|wait|pair|status|help)\b/
    refute body =~ "curl"
    refute body =~ "`"
    assert body =~ "Do not reply to this email: nobody reads the replies."

    assert String.ends_with?(
             String.trim_trailing(body),
             "Not sure how to respond? Read the docs: #{AssistantLinkWeb.Endpoint.url()}/install.md"
           )
  end

  defp latest_event(assistant, type) do
    Repo.one!(
      from e in AssistantLink.Events.Event,
        where: e.assistant_id == ^assistant.id and e.type == ^type,
        order_by: [desc: e.seq],
        limit: 1
    )
  end

  test "emails an offline Link a wake with the facts and the quoted message", %{
    conn: conn,
    link: link,
    assistant: assistant
  } do
    conn |> post_message(assistant, "Can you book the table for 8?\nOutside, please.") |> json_response(201)

    assert_receive {:email, email}, 1000
    assert email.to == [{"", "hermes@example.com"}]
    assert email.from == {"Assistant Link", "no-reply@mail.assistantlink.ai"}
    assert email.subject =~ "Hermes"
    assert email.headers["Auto-Submitted"] == "auto-generated"

    event = latest_event(assistant, :text_message)

    for expected <- [
          "Event: text_message",
          "Event id: #{event.id}",
          "Created at: #{DateTime.to_iso8601(event.inserted_at)}",
          "Link: #{link.id}",
          "> Can you book the table for 8?\n> Outside, please.",
          "Newer messages may have arrived"
        ] do
      assert email.text_body =~ expected
    end

    assert_minimal(email.text_body)
    refute_received {:webhook, _path}
  end

  test "emails the facts for call_started, but nothing for call_ended", %{conn: conn, link: link, assistant: assistant} do
    post_call_event(conn, assistant, "call_ended")
    refute_receive {:email, _email}

    post_call_event(conn, assistant, "call_started")
    assert_receive {:email, email}, 1000
    event = latest_event(assistant, :call_started)

    for expected <- [
          "Event: call_started",
          "Event id: #{event.id}",
          "Created at: #{DateTime.to_iso8601(event.inserted_at)}",
          "Link: #{link.id}"
        ] do
      assert email.text_body =~ expected
    end

    refute email.text_body =~ ">"
    assert_minimal(email.text_body)
  end

  test "emails a burst once, and again after the debounce", %{conn: conn, link: link, assistant: assistant} do
    post_message(conn, assistant, "One")
    post_message(conn, assistant, "Two")
    post_call_event(conn, assistant, "call_started")

    assert_receive {:email, email}, 1000
    assert email.text_body =~ "One"
    refute_receive {:email, _email}

    past = DateTime.shift(DateTime.utc_now(), second: -31)
    Repo.update_all(from(l in Link, where: l.id == ^link.id), set: [webhook_pinged_at: past])
    post_message(conn, assistant, "Three")
    assert_receive {:email, email}, 1000
    assert email.text_body =~ "Three"
  end

  test "does not email a Link with a live connection", %{conn: conn, link: link, assistant: assistant} do
    :ok = Links.connect(link)
    post_message(conn, assistant)
    refute_receive {:email, _email}
  end

  test "never emails an unconfirmed or cleared address", %{conn: conn, link: link, assistant: assistant} do
    {:ok, link} = Links.put_wake_email(link, %{"address" => "changed@example.com"})
    post_message(conn, assistant)
    refute_receive {:email, _email}

    {:ok, _link} = Links.delete_wake_email(link)
    post_message(conn, assistant)
    refute_receive {:email, _email}
  end

  test "a Link with a webhook gets the webhook ping and no email", %{conn: conn, link: link, assistant: assistant} do
    {:ok, _link} = Links.put_webhook(link, %{"url" => "https://a.test/hook"})
    post_message(conn, assistant)

    assert_receive {:webhook, "/hook"}, 1000
    refute_receive {:email, _email}
  end

  test "tests deliver mail to the test process, never over the network" do
    assert Application.fetch_env!(:assistant_link, AssistantLink.Mailer)[:adapter] == Swoosh.Adapters.Test
    assert Application.fetch_env!(:swoosh, :api_client) == false
  end

  test "opening the app sends no wake email", %{conn: conn} do
    conn |> post(~p"/api/v1/wake") |> response(204)
    refute_receive {:email, _email}
  end
end
