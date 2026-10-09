defmodule AssistantLinkWeb.InstallMdTest do
  use AssistantLinkWeb.ConnCase, async: true

  test "GET /install.md serves the agent install instructions as Markdown", %{conn: conn} do
    conn = get(conn, "/install.md")

    assert response(conn, 200) == File.read!(Application.app_dir(:assistant_link, "priv/static/install.md"))
    assert response_content_type(conn, :md) =~ "text/markdown"
  end

  test "the instructions cover installing, pairing, checking, waiting, and when to stop", %{conn: conn} do
    body = conn |> get("/install.md") |> response(200)

    for expected <- ["## Objective", "## Done when", "al pair", "al status", "al wait", "## Stop conditions"] do
      assert body =~ expected
    end
  end
end
