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

    assert String.ends_with?(String.trim_trailing(body), "Run `al help` and follow it.")
  end
end
