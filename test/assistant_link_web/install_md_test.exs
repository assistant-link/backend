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

    refute body =~ "Service:"
    assert body =~ "AL_SERVER"
    assert String.ends_with?(String.trim_trailing(body), "Run `al help` and follow it.")
  end

  test "the instructions register a webhook after the check, before failures", %{conn: conn} do
    body = conn |> get("/install.md") |> response(200)

    for expected <- [
          "## 5. Get woken up automatically",
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

    {check, _} = :binary.match(body, "## 4. Check")
    {webhook, _} = :binary.match(body, "## 5. Get woken up automatically")
    {failures, _} = :binary.match(body, "## If something fails")
    assert check < webhook and webhook < failures
  end
end
