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

  test "emails an offline Link a wake with the message text", %{conn: conn, link: link, assistant: assistant} do
    conn |> post_message(assistant, "Can you book the table for 8?") |> json_response(201)

    assert_receive {:email, email}, 1000
    assert email.to == [{"", "hermes@example.com"}]
    assert email.from == {"Assistant Link", "no-reply@mail.assistantlink.ai"}
    assert email.subject =~ "Hermes"
    assert email.headers["Auto-Submitted"] == "auto-generated"

    for expected <- [
          "Can you book the table for 8?",
          "Newer messages may have arrived",
          "al read",
          "al send",
          "Do not reply to this email",
          link.id
        ] do
      assert email.text_body =~ expected
    end

    refute_received {:webhook, _path}
  end

  test "emails for call_started, telling the agent to join the call, but not for call_ended",
       %{conn: conn, assistant: assistant} do
    post_call_event(conn, assistant, "call_ended")
    refute_receive {:email, _email}

    post_call_event(conn, assistant, "call_started")
    assert_receive {:email, email}, 1000
    assert email.text_body =~ "al call"
    assert email.text_body =~ "Do not reply to this email"
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
