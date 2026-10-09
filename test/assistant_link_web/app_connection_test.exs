defmodule AssistantLinkWeb.AppConnectionTest do
  # Connections run in the server's processes and Presence's, which share the test's database
  # connection only in the sandbox's shared mode.
  use AssistantLinkWeb.ConnCase, async: false

  import AssistantLink.LinksFixtures
  import AssistantLinkWeb.WebSocketClient

  alias AssistantLink.Accounts

  setup :start_server
  setup :register_device

  setup %{port: port, credential: credential} do
    {:ok, app} = open(port, "/api/v1/connect", credential)
    %{app: app}
  end

  test "requires an account credential", %{port: port, scope: scope} do
    {_link, link_token} = paired_link_fixture(scope)

    for token <- [nil, "ala_unknown", link_token] do
      assert {:error, {401, %{"error" => %{"code" => "unauthorized"}}}} = open(port, "/api/v1/connect", token)
    end
  end

  test "sends link.status when an agent connects and disconnects", %{app: app, scope: scope, port: port} do
    {link, token} = paired_link_fixture(scope)
    link_id = link.id

    {:ok, agent} = open(port, "/alp/v1/connect", token)

    assert_receive {:ws, ^app, {:text, online}}

    assert %{
             "jsonrpc" => "2.0",
             "method" => "link.status",
             "params" => %{"link_id" => ^link_id, "status" => "online", "last_active_at" => connected_at}
           } = online

    refute Map.has_key?(online, "id")
    assert {:ok, connected_at, 0} = DateTime.from_iso8601(connected_at)

    :ok = close(agent)

    assert_receive {:ws, ^app,
                    {:text,
                     %{"method" => "link.status", "params" => %{"link_id" => ^link_id, "status" => "offline"} = offline}}}

    assert {:ok, disconnected_at, 0} = DateTime.from_iso8601(offline["last_active_at"])
    assert DateTime.after?(disconnected_at, connected_at)
    :ok = close(app)
  end

  test "sends only its own account's link.status", %{app: app, port: port} do
    other = register_device(%{conn: build_conn()})
    {link, token} = paired_link_fixture(other.scope)
    :ok = Accounts.subscribe(other.account.id)
    link_id = link.id

    {:ok, agent} = open(port, "/alp/v1/connect", token)
    assert_receive {:link_status, %{link_id: ^link_id, status: :online}}
    :ok = close(agent)
    assert_receive {:link_status, %{link_id: ^link_id, status: :offline}}

    refute_received {:ws, ^app, {:text, _message}}
    :ok = close(app)
  end

  test "answers unknown methods and malformed frames with JSON-RPC errors", %{app: app} do
    :ok = send_text(app, Jason.encode!(%{jsonrpc: "2.0", id: "a1", method: "assistants.list"}))
    assert_receive {:ws, ^app, {:text, %{"id" => "a1", "error" => %{"code" => -32_601}}}}

    :ok = send_text(app, "]")
    assert_receive {:ws, ^app, {:text, %{"id" => nil, "error" => %{"code" => -32_700}}}}

    :ok = close(app)
  end

  test "closes with account_deleted when the account is deleted", %{app: app, scope: scope} do
    :ok = Accounts.delete_account(scope)

    assert_receive {:ws, ^app,
                    {:text, %{"method" => "connection.closing", "params" => %{"reason" => "account_deleted"}}}}

    assert_receive {:ws, ^app, {:closed, 1000, "account_deleted"}}
  end
end
