defmodule AssistantLinkWeb.PageControllerTest do
  use AssistantLinkWeb.ConnCase, async: true

  test "GET / shows only the product name", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)
    document = LazyHTML.from_document(html)

    assert text(document, "title") == "Assistant Link"
    assert text(document, "body") == "Assistant Link"
    refute html =~ ~r/phoenix/i
  end

  defp text(document, selector) do
    document |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()
  end
end
