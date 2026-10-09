defmodule AssistantLinkWeb.ErrorJSONTest do
  use AssistantLinkWeb.ConnCase, async: true

  test "renders 404 in the API error format" do
    assert AssistantLinkWeb.ErrorJSON.render("404.json", %{}) ==
             %{error: %{code: "not_found", message: "Not Found"}}
  end

  test "renders 500 in the API error format" do
    assert AssistantLinkWeb.ErrorJSON.render("500.json", %{}) ==
             %{error: %{code: "internal_server_error", message: "Internal Server Error"}}
  end
end
