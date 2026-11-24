defmodule AssistantLinkWeb.InstallMdTest do
  use AssistantLinkWeb.ConnCase, async: true

  @cli "## With `al`\n"
  @protocol "## Protocol only\n"
  @wake "## How wake-ups work\n"

  setup %{conn: conn} do
    %{body: conn |> get("/install.md") |> response(200)}
  end

  # The text from `heading` up to the next heading of the same level.
  defp section(body, heading) do
    [_, rest] = String.split(body, heading, parts: 2)
    level = heading |> String.split(" ") |> hd()
    rest |> String.split(~r/^#{level} /m, parts: 2) |> hd()
  end

  # Prose wraps at any space, so a phrase matches across line breaks.
  defp assert_contains(text, expected) do
    text = String.replace(text, ~r/\s+/, " ")
    for e <- expected, do: assert(text =~ e, "missing: #{e}")
  end

  defp assert_order(text, parts) do
    positions = for part <- parts, do: text |> :binary.match(part) |> elem(0)
    assert positions == Enum.sort(positions), "out of order: #{inspect(parts)}"
  end

  test "GET /install.md serves the agent install instructions as Markdown", %{conn: conn} do
    conn = get(conn, "/install.md")

    assert response(conn, 200) == File.read!(Application.app_dir(:assistant_link, "priv/static/install.md"))
    assert response_content_type(conn, :md) =~ "text/markdown"
  end

  test "the top offers the al path and the protocol-only path as equal entry points", %{body: body} do
    [top, _] = String.split(body, ~r/^## /m, parts: 2)

    assert_contains(top, [
      "[With `al`](#with-al)",
      "[Protocol only](#protocol-only)",
      "cannot install software",
      "HTTPS",
      "WebSocket",
      "JSON-RPC 2.0",
      "https://assistant-link.fly.dev",
      ~s(the "Service:" line names another)
    ])

    [done] = Regex.run(~r/Done when [^.]*\./, top)
    assert_contains(done, ["reply permission", "al-hermes status", "GET /alp/v1/link", "webhook", "wake email"])

    assert_order(body, [@cli, @protocol, @wake])
  end

  test "the reply permission is saved once, right after pairing, on both paths", %{body: body} do
    assert_contains(section(body, "## Reply permission\n"), [
      "memory or policy",
      "never messages to anyone else, spending, or account changes",
      "ask the user once",
      "before the first test",
      "never per message",
      "their own chat"
    ])

    assert_order(section(body, @cli), ["### 2. Pair", "### 3. Save the reply permission", "### 4. Store the key"])

    assert_order(section(body, @protocol), [
      "### 1. Pair",
      "### 2. Save the reply permission",
      "### 3. Store the token"
    ])
  end

  test "the al path installs, pairs, stores the key, checks, and ends with al help", %{body: body} do
    cli = section(body, @cli)

    assert_contains(cli, [
      "### 1. Install `al`",
      "al pair K7QM-2XPA --key-file",
      ~s(# the "One-time code:" line),
      "AL_SERVER",
      "al-hermes status",
      "al-hermes assistant set --platform <value>",
      "al-hermes assistant show"
      | ~w(muse grokbot dots duet hermes openclaw instinct)
    ])

    assert_contains(cli, [
      "al-hermes webhook set",
      "al-hermes webhook show",
      "al-hermes webhook clear",
      "--header \"Authorization: <value>\"",
      "AL_WEBHOOK_HEADER",
      "al-hermes wake-email set <your-email-address>",
      "al-hermes wake-email show",
      "al-hermes wake-email clear",
      "al-hermes wait",
      "al-hermes read",
      "al-hermes send",
      "al-hermes call",
      "### If `al` fails"
    ])

    assert_order(cli, ["### 5. Check", "assistant set --platform", "### 6. Get woken up", "### If `al` fails"])
    assert String.ends_with?(String.trim_trailing(cli), "Run `al help` and follow it.")
    refute cli =~ "Authorization: Bearer"
  end

  test "the protocol-only path needs no software and never prints or moves the token", %{body: body} do
    protocol = section(body, @protocol)

    for cli_only <- ["al-hermes", "al pair", "cargo", "Keychain", "secret-tool", "wrapper", "AL_SERVER"] do
      refute protocol =~ cli_only
    end

    assert_contains(protocol, [
      "POST https://assistant-link.fly.dev/alp/v1/pair",
      ~s({"code": "K7QM-2XPA"}),
      "15 minutes",
      "returned only once",
      "new pairing text",
      "secret store or password vault",
      "together with the service URL",
      "approve",
      "Never print the token",
      "never ask the user to paste",
      "to any other service",
      ~s(auth | curl -fsS "$SERVICE/alp/v1/link" -H @-),
      "unread_count",
      ~s(-X PATCH "$SERVICE/alp/v1/assistant"),
      ~s({"platform": "<value>"})
      | ~w(muse grokbot dots duet hermes openclaw instinct)
    ])
  end

  test "the protocol-only path registers and checks the wake routes with curl", %{body: body} do
    protocol = section(body, @protocol)

    for path <- ["webhook", "wake_email"], method <- ["PUT", "DELETE"] do
      assert protocol =~ ~s(-X #{method} "$SERVICE/alp/v1/link/#{path}")
    end

    assert_contains(protocol, [
      ~s(auth | curl -fsS "$SERVICE/alp/v1/link/webhook" -H @-),
      ~s(auth | curl -fsS "$SERVICE/alp/v1/link/wake_email" -H @-),
      ~s({"url": "https://<your-webhook-url>", "authorization": "<value>"}),
      ~s({"address": "<your-email-address>"}),
      ~s("confirmed": false),
      "curl -X POST <link>",
      "[How wake-ups work](#how-wake-ups-work)"
    ])
  end

  test "the protocol-only path catches up, acknowledges, dedupes, replies, and answers calls", %{body: body} do
    protocol = section(body, @protocol)

    assert_contains(protocol, [
      "GET wss://assistant-link.fly.dev/alp/v1/connect",
      "connection.ready",
      "event.deliver",
      ~s({"jsonrpc": "2.0", "id": <the request's id>, "result": {"event_id": "<the event's id>"}}),
      "received, not answered",
      "event_id",
      "already handled",
      "connection.caught_up",
      "waiting when the connection opened",
      "not that nothing newer",
      ~s(-X POST "$SERVICE/alp/v1/messages"),
      ~s({"text": "<your answer>", "idempotency_key": "<a new UUIDv7>"}),
      "call_started",
      ~s("via": "voice"),
      "call_ended",
      "reads your text replies aloud",
      "no audio endpoint",
      "`al call`",
      "docs/alp/client.mjs",
      "docs/alp/v1.md"
    ])

    assert_order(protocol, ["connection.ready", "event.deliver", "connection.caught_up", "call_started"])
  end

  test "both paths let the agent hang up a call", %{body: body} do
    assert_contains(section(body, @cli), ["al-hermes hangup", "al-hermes call` exits 0", "call_ended"])

    protocol = section(body, "### 7. Calls\n")

    assert_contains(protocol, [
      ~s(auth | curl -fsS -X POST "$SERVICE/alp/v1/hangup" -H @-),
      "not_on_call",
      "call_ended"
    ])

    assert_order(protocol, ["Close when `call_ended` arrives", "/alp/v1/hangup"])
  end

  test "both paths share how wake-ups work", %{body: body} do
    wake = section(body, @wake)

    assert_contains(wake, [
      ~s({"type":"wake","link_id":"..."}),
      "Opening the app also sends a webhook ping, but no wake email",
      "no-reply@mail.assistantlink.ai",
      "24 hours",
      "opening the link alone",
      "confirms nothing",
      "A Link with a webhook is woken only by the webhook",
      "setting a wake email does not remove the webhook",
      "30 seconds",
      "10 minutes",
      "best effort",
      "Do not reply",
      "data from the user"
    ])

    for path <- [@cli, @protocol], do: assert(section(body, path) =~ "[How wake-ups work](#how-wake-ups-work)")
  end

  test "every ALP path the instructions name is served", %{body: body} do
    paths = ~r{/alp/v1/[a-z_/]*[a-z]} |> Regex.scan(body) |> List.flatten() |> Enum.uniq()

    assert "/alp/v1/link/wake_email" in paths

    for path <- paths do
      assert Enum.any?(~w(GET POST PUT PATCH DELETE), fn method ->
               Phoenix.Router.route_info(AssistantLinkWeb.Router, method, path, "localhost") != :error
             end),
             "not routed: #{path}"
    end
  end
end
