defmodule AssistantLinkWeb.InstallMdTest do
  use AssistantLinkWeb.ConnCase, async: true

  test "GET /install.md serves the agent install instructions as Markdown", %{conn: conn} do
    conn = get(conn, "/install.md")

    assert response(conn, 200) == File.read!(Application.app_dir(:assistant_link, "priv/static/install.md"))
    assert response_content_type(conn, :md) =~ "text/markdown"
  end

  test "the instructions install, pair, store the key, check, and end with al help", %{conn: conn} do
    body = conn |> get("/install.md") |> response(200)

    for expected <- ["## 1. Install `al`", "al pair", "al-hermes", "al-hermes status", "## If something fails"] do
      assert body =~ expected
    end

    assert body =~ ~s(# the "One-time code:" line)
    assert body =~ ~s(the "Service:" line names another)
    assert body =~ "AL_SERVER"
    assert String.ends_with?(String.trim_trailing(body), "Run `al help` and follow it.")
  end

  test "the instructions set the platform right after pairing, listing the known values", %{conn: conn} do
    body = conn |> get("/install.md") |> response(200)

    for expected <- ["al-hermes assistant set --platform <value>" | ~w(muse grokbot dots duet hermes openclaw instinct)] do
      assert body =~ expected
    end

    assert body =~ "PATCH https://assistant-link.fly.dev/alp/v1/assistant"
    assert body =~ ~s({"platform": "<value>"})

    {check, _} = :binary.match(body, "## 5. Check")
    {platform, _} = :binary.match(body, "assistant set --platform")
    {webhook, _} = :binary.match(body, "## 6. Get woken up automatically")
    assert check < platform and platform < webhook
  end

  test "the instructions register a webhook after the check, before failures", %{conn: conn} do
    body = conn |> get("/install.md") |> response(200)

    for expected <- [
          "## 6. Get woken up automatically",
          "al-hermes webhook set",
          "al-hermes webhook show",
          "al-hermes webhook clear",
          "--header \"Authorization: <value>\"",
          "AL_WEBHOOK_HEADER",
          "PUT https://assistant-link.fly.dev/alp/v1/link/webhook",
          "Authorization: Bearer <Link key>",
          ~s({"type":"wake","link_id":"..."}),
          "30 seconds",
          "al-hermes read",
          "al-hermes call",
          "call_started",
          "al-hermes send",
          "al-hermes wait"
        ] do
      assert body =~ expected
    end

    [done] = Regex.run(~r/Done when [^.]*\./, body)
    assert done =~ "(step 3)"
    assert done =~ "(step 5)"
    assert done =~ "webhook"
    assert done =~ "(step 6)"

    {check, _} = :binary.match(body, "## 5. Check")
    {webhook, _} = :binary.match(body, "## 6. Get woken up automatically")
    {failures, _} = :binary.match(body, "## If something fails")
    assert check < webhook and webhook < failures
  end

  # Right after pairing: a later step can stall setup, and a registered webhook can wake the agent at once.
  test "the instructions save the user's reply permission once, right after pairing", %{conn: conn} do
    body = conn |> get("/install.md") |> response(200)
    [_, permission] = String.split(body, "## 2. Pair\n", parts: 2)
    [_, permission] = String.split(permission, "## 3. Save the reply permission\n", parts: 2)
    [permission, _] = String.split(permission, "## 4. Store the key\n", parts: 2)

    for expected <- [
          "memory or policy",
          "never messages to anyone else, spending, or account changes",
          "ask the user once",
          "never per message",
          "their own chat"
        ] do
      assert permission =~ expected
    end
  end

  test "the instructions offer a confirmed wake email when the platform has no webhooks", %{conn: conn} do
    body = conn |> get("/install.md") |> response(200)

    for expected <- [
          "al-hermes wake-email set <your-email-address>",
          "al-hermes wake-email show",
          "al-hermes wake-email clear",
          "PUT https://assistant-link.fly.dev/alp/v1/link/wake_email",
          ~s({"address": "<your-email-address>"}),
          "confirmation",
          "24 hours",
          "curl -X POST",
          "Do not reply",
          "al-hermes read",
          "al-hermes send",
          "DELETE"
        ] do
      assert body =~ expected
    end

    refute body =~ "until then, call the API"

    {webhook, _} = :binary.match(body, "## 6. Get woken up automatically")
    {email, _} = :binary.match(body, "/alp/v1/link/wake_email")
    {failures, _} = :binary.match(body, "## If something fails")
    assert webhook < email and email < failures
  end

  test "the instructions say how to answer after a wake, with al and with the API only", %{conn: conn} do
    body = conn |> get("/install.md") |> response(200)
    [_, answer] = String.split(body, "### Answer after a wake\n", parts: 2)
    [answer, _] = String.split(answer, "## If something fails", parts: 2)

    for expected <- [
          "al-hermes read",
          "al-hermes send",
          "al-hermes call",
          "call_started",
          "call_ended",
          "GET wss://assistant-link.fly.dev/alp/v1/connect",
          "Authorization: Bearer <Link key>",
          "event.deliver",
          ~s("result": {"event_id": "<the event's id>"}),
          "connection.caught_up",
          "POST https://assistant-link.fly.dev/alp/v1/messages",
          ~s({"text": "<your answer>", "idempotency_key": "<a new UUIDv7>"}),
          ~s("via": "voice"),
          "docs/alp/v1.md"
        ] do
      assert answer =~ expected
    end

    assert body =~ "[Answer after a wake](#answer-after-a-wake)"
  end
end
