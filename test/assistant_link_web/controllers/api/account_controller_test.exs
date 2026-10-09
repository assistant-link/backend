defmodule AssistantLinkWeb.API.AccountControllerTest do
  use AssistantLinkWeb.ConnCase, async: true

  import Ecto.Query

  alias AssistantLink.Accounts.Account
  alias AssistantLink.Accounts.Device
  alias AssistantLink.Accounts.Membership
  alias AssistantLink.Accounts.User
  alias AssistantLink.Assistants
  alias AssistantLink.Assistants.Assistant
  alias AssistantLink.Links
  alias AssistantLink.Links.Link
  alias AssistantLink.Links.PairingCode
  alias AssistantLink.Repo
  alias AssistantLink.Tokens

  describe "POST /api/v1/accounts" do
    test "registers an anonymous user who owns a new account, with a device", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/accounts")

      assert %{"account_id" => account_id, "credential" => "ala_" <> _ = credential} = json_response(conn, 201)

      assert [%Membership{role: :owner, user_id: user_id}] =
               Repo.all(from m in Membership, where: m.account_id == ^account_id)

      assert %User{email: nil} = Repo.get!(User, user_id)
      assert [%Device{user_id: ^user_id, account_id: ^account_id} = device] = Repo.all(Device)
      assert device.token_hash == Tokens.hash(credential)
    end

    test "stores only the credential's hash", %{conn: conn} do
      %{"credential" => credential} = conn |> post(~p"/api/v1/accounts") |> json_response(201)

      [device] = Repo.all(Device)
      refute device.token_hash =~ credential
      assert byte_size(device.token_hash) == 32
    end

    test "returns a credential that authenticates the API", %{conn: conn} do
      %{"credential" => credential} = conn |> post(~p"/api/v1/accounts") |> json_response(201)

      conn = build_conn() |> authenticate_device(credential) |> get(~p"/api/v1/assistants")

      assert json_response(conn, 200) == %{"assistants" => []}
    end

    test "registers a separate account each time", %{conn: conn} do
      first = conn |> post(~p"/api/v1/accounts") |> json_response(201)
      second = build_conn() |> post(~p"/api/v1/accounts") |> json_response(201)

      assert first["account_id"] != second["account_id"]
      assert first["credential"] != second["credential"]
    end
  end

  describe "DELETE /api/v1/account" do
    setup :register_device

    test "deletes the account, everything it owns, and its users", %{conn: conn, scope: scope} do
      {:ok, assistant} = Assistants.create_assistant(scope, %{"name" => "Hermes", "avatar" => "avatar-1"})
      {:ok, link} = Links.create_link(scope, assistant.id, %{})
      {:ok, _pairing} = Links.issue_pairing_code(scope, link.id)

      other = register_device(%{conn: build_conn()})
      {:ok, _other_assistant} = Assistants.create_assistant(other.scope, %{"name" => "Muse", "avatar" => "avatar-2"})

      conn = delete(conn, ~p"/api/v1/account")

      assert response(conn, 204) == ""
      refute Repo.get(Account, scope.account.id)
      refute Repo.get(User, scope.user.id)

      for schema <- [User, Device, Membership, Account, Assistant] do
        assert Repo.aggregate(schema, :count) == 1, "expected only the other account's #{inspect(schema)}"
      end

      assert Repo.aggregate(Link, :count) == 0
      assert Repo.aggregate(PairingCode, :count) == 0
      assert Repo.get(Account, other.account.id)
    end

    test "the deleted account's credential no longer works", %{conn: conn, credential: credential} do
      delete(conn, ~p"/api/v1/account")

      conn = build_conn() |> authenticate_device(credential) |> get(~p"/api/v1/assistants")

      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
    end

    test "requires an account credential" do
      conn = delete(build_conn(), ~p"/api/v1/account")

      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
    end
  end
end
