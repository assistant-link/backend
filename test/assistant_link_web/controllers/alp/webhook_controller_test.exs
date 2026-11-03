defmodule AssistantLinkWeb.ALP.WebhookControllerTest do
  use AssistantLinkWeb.ConnCase, async: true

  import AssistantLink.LinksFixtures

  setup :register_device

  setup %{conn: conn, scope: scope} do
    {_link, token} = paired_link_fixture(scope)
    %{conn: put_req_header(conn, "authorization", "Bearer " <> token)}
  end

  test "sets, shows and clears the webhook with a masked authorization", %{conn: conn} do
    assert conn |> get(~p"/alp/v1/link/webhook") |> json_response(200) == %{"webhook" => nil}

    params = %{"url" => "https://a.test/hook", "authorization" => "Bearer secret"}
    shown = %{"webhook" => %{"url" => "https://a.test/hook", "authorization" => "Bearer ***"}}

    assert conn |> put(~p"/alp/v1/link/webhook", params) |> json_response(200) == shown
    assert conn |> get(~p"/alp/v1/link/webhook") |> json_response(200) == shown

    assert conn |> delete(~p"/alp/v1/link/webhook") |> response(204)
    assert conn |> get(~p"/alp/v1/link/webhook") |> json_response(200) == %{"webhook" => nil}
  end

  test "answers 422 invalid_params for an invalid webhook", %{conn: conn} do
    body = conn |> put(~p"/alp/v1/link/webhook", %{"url" => "ftp://a.test"}) |> json_response(422)
    assert body["error"]["code"] == "invalid_params"
  end
end
