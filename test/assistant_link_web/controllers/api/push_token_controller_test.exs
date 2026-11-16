defmodule AssistantLinkWeb.API.PushTokenControllerTest do
  use AssistantLinkWeb.ConnCase, async: true

  alias AssistantLink.Accounts
  alias AssistantLink.Accounts.Device
  alias AssistantLink.Repo

  setup :register_device

  @token String.duplicate("ab12", 16)

  defp push_token(scope), do: Repo.get!(Device, scope.device.id).push_token

  describe "PUT /api/v1/device/push_token" do
    test "stores the device's APNs token and answers 204", %{conn: conn, scope: scope} do
      assert conn |> put(~p"/api/v1/device/push_token", %{"token" => @token}) |> response(204) == ""
      assert push_token(scope) == @token
    end

    test "replaces the device's token and stores it in lowercase", %{conn: conn, scope: scope} do
      put(conn, ~p"/api/v1/device/push_token", %{"token" => @token})
      new_token = String.duplicate("CD34", 16)

      assert conn |> put(~p"/api/v1/device/push_token", %{"token" => new_token}) |> response(204)
      assert push_token(scope) == String.downcase(new_token)
    end

    test "moves a token another device registered to this one", %{conn: conn, scope: scope} do
      %{conn: other_conn, scope: other_scope} = register_device(%{conn: build_conn()})
      put(other_conn, ~p"/api/v1/device/push_token", %{"token" => @token})

      assert conn |> put(~p"/api/v1/device/push_token", %{"token" => @token}) |> response(204)
      assert push_token(scope) == @token
      assert push_token(other_scope) == nil
    end

    test "is 422 for a token that is not hex", %{conn: conn, scope: scope} do
      for token <- ["", "not-hex", String.duplicate("a", 201), 42, nil] do
        conn = put(conn, ~p"/api/v1/device/push_token", %{"token" => token})
        assert json_response(conn, 422)["error"]["code"] == "invalid_params"
      end

      assert push_token(scope) == nil
    end

    test "is 401 without a credential" do
      conn = put(build_conn(), ~p"/api/v1/device/push_token", %{"token" => @token})
      assert json_response(conn, 401)
    end
  end

  describe "DELETE /api/v1/device/push_token" do
    test "removes the device's token and answers 204", %{conn: conn, scope: scope} do
      put(conn, ~p"/api/v1/device/push_token", %{"token" => @token})

      assert conn |> delete(~p"/api/v1/device/push_token") |> response(204) == ""
      assert push_token(scope) == nil
      assert conn |> delete(~p"/api/v1/device/push_token") |> response(204) == ""
    end

    test "is 401 without a credential" do
      assert build_conn() |> delete(~p"/api/v1/device/push_token") |> json_response(401)
    end
  end

  test "a device's tokens belong to its account", %{conn: conn, account: account} do
    put(conn, ~p"/api/v1/device/push_token", %{"token" => @token})
    assert Accounts.list_push_tokens(account.id) == [@token]
  end
end
