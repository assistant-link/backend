defmodule AssistantLinkWeb.AppConnectionTest do
  # Connections run in the server's processes and Presence's, which share the test's database
  # connection only in the sandbox's shared mode.
  use AssistantLinkWeb.ConnCase, async: false

  import AssistantLink.LinksFixtures
  import AssistantLinkWeb.WebSocketClient

  alias AssistantLink.Accounts
  alias AssistantLink.Events

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

  test "rejects the credential of a deleted account", %{port: port, credential: credential, scope: scope} do
    :ok = Accounts.delete_account(scope)

    assert {:error, {401, %{"error" => %{"code" => "unauthorized"}}}} = open(port, "/api/v1/connect", credential)
  end

  test "closes a connection opened for an account deleted after authentication", %{scope: scope} do
    :ok = Accounts.delete_account(scope)
    state = %{role: {:app, scope.account.id}, ping_interval: 1_000}

    assert {:stop, :normal, {1000, "account_deleted"}, [{:text, closing}], _state} =
             AssistantLinkWeb.Connection.init(state)

    assert %{"method" => "connection.closing", "params" => %{"reason" => "account_deleted"}} = Jason.decode!(closing)
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

  describe "events" do
    setup %{scope: scope} do
      {link, token} = paired_link_fixture(scope)
      %{link: link, token: token}
    end

    defp message_params, do: %{"text" => "Hi", "idempotency_key" => Ecto.UUID.generate(version: 7)}

    test "sends event.created for the user's stored text message", %{app: app, scope: scope, link: link} do
      {:ok, %{id: id}, :created} = Events.create_text_message(scope, link.assistant_id, message_params())

      assert_receive {:ws, ^app,
                      {:text, %{"jsonrpc" => "2.0", "method" => "event.created", "params" => params} = notice}}

      refute Map.has_key?(notice, "id")

      assert %{
               "event" => %{
                 "id" => ^id,
                 "type" => "text_message",
                 "sender" => "user",
                 "delivery_status" => "sent",
                 "text_message" => %{"text" => "Hi"}
               }
             } = params

      :ok = close(app)
    end

    test "sends one event.updated when a Link first acknowledges the message", %{app: app, scope: scope, link: link} do
      {:ok, %{id: id}, :created} = Events.create_text_message(scope, link.assistant_id, message_params())
      assert_receive {:ws, ^app, {:text, %{"method" => "event.created"}}}

      :ok = Events.mark_delivered(scope.account.id, id)
      :ok = Events.mark_delivered(scope.account.id, id)

      assert_receive {:ws, ^app,
                      {:text,
                       %{
                         "method" => "event.updated",
                         "params" => %{"event" => %{"id" => ^id, "delivery_status" => "delivered"}}
                       }}}

      refute_receive {:ws, ^app, {:text, _message}}
      :ok = close(app)
    end

    test "sends every connection of the account the event, and no other account", %{
      app: app,
      scope: scope,
      link: link,
      port: port,
      credential: credential
    } do
      {:ok, second_app} = open(port, "/api/v1/connect", credential)
      other = register_device(%{conn: build_conn()})
      {other_link, _token} = paired_link_fixture(other.scope)
      {:ok, other_app} = open(port, "/api/v1/connect", other.credential)

      {:ok, _event, :created} = Events.create_text_message(scope, link.assistant_id, message_params())

      assert_receive {:ws, ^app, {:text, %{"method" => "event.created"}}}
      assert_receive {:ws, ^second_app, {:text, %{"method" => "event.created"}}}
      refute_receive {:ws, ^other_app, {:text, _message}}

      {:ok, _event, :created} = Events.create_text_message(other.scope, other_link.assistant_id, message_params())

      assert_receive {:ws, ^other_app, {:text, %{"method" => "event.created"}}}
      refute_receive {:ws, ^app, {:text, _message}}
      refute_receive {:ws, ^second_app, {:text, _message}}

      for client <- [app, second_app, other_app], do: :ok = close(client)
    end
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
