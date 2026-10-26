defmodule AssistantLinkWeb.Plugs.BearerAuthTest do
  use AssistantLinkWeb.ConnCase, async: true

  import AssistantLink.AccountsFixtures
  import Ecto.Query

  alias AssistantLink.Accounts.Account
  alias AssistantLink.Accounts.Device
  alias AssistantLink.Assistants.Assistant
  alias AssistantLink.Links.Link
  alias AssistantLink.Repo
  alias AssistantLink.Tokens
  alias AssistantLinkWeb.Plugs.BearerAuth

  setup do
    user = user_fixture()
    account = owned_account(user)
    {device, device_token} = device_fixture(user)
    link_token = Tokens.generate(:link)
    assistant = Repo.insert!(%Assistant{account_id: account.id, name: "Hermes", avatar: "avatar-1"})
    link = Repo.insert!(%Link{account_id: account.id, assistant_id: assistant.id, token_hash: Tokens.hash(link_token)})

    %{user: user, account: account, device: device, device_token: device_token, link: link, link_token: link_token}
  end

  defp authenticate(conn, kind, header \\ nil) do
    conn
    |> then(&if(header, do: put_req_header(&1, "authorization", header), else: &1))
    |> BearerAuth.call(BearerAuth.init(kind))
  end

  defp soft_delete(account) do
    Repo.update_all(from(a in Account, where: a.id == ^account.id), set: [deleted_at: DateTime.utc_now()])
  end

  defp assert_unauthorized(conn) do
    assert conn.halted

    assert json_response(conn, 401) == %{
             "error" => %{"code" => "unauthorized", "message" => "Missing or invalid bearer token."}
           }
  end

  describe "account credentials" do
    test "a valid credential assigns the scope with the user and account", context do
      conn = authenticate(context.conn, :account, "Bearer " <> context.device_token)

      refute conn.halted
      assert conn.assigns.current_scope.user.id == context.user.id
      assert conn.assigns.current_scope.account.id == context.account.id
    end

    test "a valid credential records when the device was last seen", context do
      assert context.device.last_seen_at == nil

      authenticate(context.conn, :account, "Bearer " <> context.device_token)

      assert %DateTime{} = Repo.get!(Device, context.device.id).last_seen_at
    end

    test "the scheme is case-insensitive", %{conn: conn, device_token: token} do
      refute authenticate(conn, :account, "bearer " <> token).halted
    end

    test "a missing header is rejected", %{conn: conn} do
      conn |> authenticate(:account) |> assert_unauthorized()
    end

    test "an unknown or malformed credential is rejected", %{conn: conn, link_token: link_token} do
      for header <- ["Bearer " <> Tokens.generate(:account), "Bearer ", "Basic abc", "ala_xyz", "Bearer " <> link_token] do
        conn |> authenticate(:account, header) |> assert_unauthorized()
      end
    end

    test "a credential is rejected once its device is removed", context do
      Repo.delete_all(from d in Device, where: d.id == ^context.device.id)

      context.conn |> authenticate(:account, "Bearer " <> context.device_token) |> assert_unauthorized()
    end

    test "the credential of a deleted account is rejected", %{conn: conn, account: account, device_token: token} do
      soft_delete(account)

      conn |> authenticate(:account, "Bearer " <> token) |> assert_unauthorized()
    end
  end

  describe "Link tokens" do
    test "a valid token assigns the Link with its Assistant", %{conn: conn, link: link, link_token: token} do
      conn = authenticate(conn, :link, "Bearer " <> token)

      refute conn.halted
      assert conn.assigns.current_link.id == link.id
      assert conn.assigns.current_link.assistant.name == "Hermes"
    end

    test "a missing or unknown token is rejected", %{conn: conn, device_token: device_token} do
      conn |> authenticate(:link) |> assert_unauthorized()

      for header <- ["Bearer " <> Tokens.generate(:link), "Bearer " <> device_token] do
        conn |> authenticate(:link, header) |> assert_unauthorized()
      end
    end

    test "the token of a Link whose account was deleted is rejected", %{conn: conn, account: account, link_token: token} do
      soft_delete(account)

      conn |> authenticate(:link, "Bearer " <> token) |> assert_unauthorized()
    end
  end
end
