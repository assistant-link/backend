defmodule AssistantLinkWeb.ALPConnectionTest do
  # Connections run in the server's processes and Presence's, which share the test's database
  # connection only in the sandbox's shared mode.
  use AssistantLinkWeb.ConnCase, async: false

  import AssistantLink.LinksFixtures
  import AssistantLinkWeb.WebSocketClient

  alias AssistantLink.Accounts
  alias AssistantLink.Links
  alias AssistantLink.Links.Link
  alias AssistantLink.Repo

  setup :start_server
  setup :register_device

  setup %{scope: scope, account: account} do
    {link, token} = paired_link_fixture(scope)
    :ok = Accounts.subscribe(account.id)
    %{link: link, token: token}
  end

  defp connect_agent(context, opts \\ []) do
    {:ok, client} = open(context.port, "/alp/v1/connect", context.token, opts)
    assert_receive {:ws, ^client, {:text, %{"method" => "connection.ready"}}}
    client
  end

  defp disconnect_last(client, link) do
    :ok = close(client)
    link_id = link.id
    assert_receive {:link_status, %{link_id: ^link_id, status: :offline}}
  end

  defp request(client, message) do
    :ok = send_text(client, Jason.encode!(message))
    assert_receive {:ws, ^client, {:text, reply}}
    reply
  end

  describe "upgrade" do
    test "requires a Link token", %{port: port} do
      for token <- [nil, "alt_unknown"] do
        assert {:error, {401, %{"error" => %{"code" => "unauthorized"}}}} = open(port, "/alp/v1/connect", token)
      end
    end

    test "rejects an account credential", %{port: port, credential: credential} do
      assert {:error, {401, _body}} = open(port, "/alp/v1/connect", credential)
    end

    test "rejects the token of a deleted account's Link", %{port: port, token: token, scope: scope} do
      :ok = Accounts.delete_account(scope)

      assert {:error, {401, %{"error" => %{"code" => "unauthorized"}}}} = open(port, "/alp/v1/connect", token)
    end
  end

  describe "messages" do
    test "the first message is connection.ready", %{port: port, token: token, link: link} do
      {:ok, client} = open(port, "/alp/v1/connect", token)

      assert_receive {:ws, ^client, {:text, ready}}

      assert ready == %{
               "jsonrpc" => "2.0",
               "method" => "connection.ready",
               "params" => %{"link_id" => link.id, "assistant_name" => "Hermes", "protocol_version" => "1"}
             }

      disconnect_last(client, link)
    end

    test "answers an unknown method with -32601 and stays open", context do
      client = connect_agent(context)

      for id <- [1, 2] do
        assert %{"id" => ^id, "error" => %{"code" => -32_601}} =
                 request(client, %{jsonrpc: "2.0", id: id, method: "something.new"})
      end

      disconnect_last(client, context.link)
    end

    test "answers malformed frames with JSON-RPC errors and stays open", context do
      client = connect_agent(context)

      :ok = send_text(client, "{not json")
      assert_receive {:ws, ^client, {:text, %{"id" => nil, "error" => %{"code" => -32_700}}}}

      :ok = send_text(client, Jason.encode!([%{jsonrpc: "2.0", id: 1, method: "a.b"}]))
      assert_receive {:ws, ^client, {:text, %{"id" => nil, "error" => %{"code" => -32_600}}}}

      :ok = send_binary(client, <<1, 2, 3>>)
      assert_receive {:ws, ^client, {:text, %{"id" => nil, "error" => %{"code" => -32_600}}}}

      assert %{"id" => 3, "error" => %{"code" => -32_601}} = request(client, %{jsonrpc: "2.0", id: 3, method: "a.b"})

      disconnect_last(client, context.link)
    end

    test "notifications get no answer", context do
      client = connect_agent(context)

      :ok = send_text(client, Jason.encode!(%{jsonrpc: "2.0", method: "something.new"}))

      assert %{"id" => 1} = request(client, %{jsonrpc: "2.0", id: 1, method: "a.b"})
      refute_received {:ws, ^client, {:text, _message}}

      disconnect_last(client, context.link)
    end
  end

  describe "presence" do
    test "a connected Link is online and records when it was active", %{link: link} = context do
      before = DateTime.utc_now()
      client = connect_agent(context)
      link_id = link.id

      assert_receive {:link_status, %{link_id: ^link_id, status: :online, last_active_at: connected_at}}
      assert Links.status(link) == :online
      assert DateTime.compare(connected_at, before) != :lt
      assert Repo.get!(Link, link.id).last_active_at == connected_at

      disconnect_last(client, link)
    end

    test "a clean close takes the Link offline and records the disconnect", %{link: link} = context do
      client = connect_agent(context)
      link_id = link.id
      assert_receive {:link_status, %{link_id: ^link_id, status: :online, last_active_at: connected_at}}

      :ok = close(client)

      assert_receive {:link_status, %{link_id: ^link_id, status: :offline, last_active_at: disconnected_at}}
      assert DateTime.after?(disconnected_at, connected_at)
      assert Links.status(link) == :offline
      assert Repo.get!(Link, link.id).last_active_at == disconnected_at
    end

    test "a Link stays online until its last connection closes", %{link: link} = context do
      first = connect_agent(context)
      second = connect_agent(context)
      link_id = link.id

      assert_receive {:link_status, %{link_id: ^link_id, status: :online, last_active_at: connected_at}}

      :ok = close(first)

      refute_receive {:link_status, %{link_id: ^link_id}}, 200
      assert Links.status(link) == :online
      first_closed_at = Repo.get!(Link, link.id).last_active_at
      assert DateTime.after?(first_closed_at, connected_at)

      :ok = close(second)

      assert_receive {:link_status, %{link_id: ^link_id, status: :offline, last_active_at: disconnected_at}}
      assert DateTime.after?(disconnected_at, first_closed_at)
      assert Repo.get!(Link, link.id).last_active_at == disconnected_at
    end

    test "Links are online independently", %{scope: scope, link: link} = context do
      {other_link, other_token} = another_paired_link_fixture(scope, Repo.preload(link, :assistant).assistant)
      client = connect_agent(context)
      other_client = connect_agent(%{context | token: other_token})

      assert Links.status(link) == :online
      assert Links.status(other_link) == :online

      disconnect_last(other_client, other_link)
      assert Links.status(link) == :online

      disconnect_last(client, link)
    end
  end

  describe "liveness" do
    setup do
      config = Application.fetch_env!(:assistant_link, AssistantLinkWeb.Connection)
      Application.put_env(:assistant_link, AssistantLinkWeb.Connection, ping_interval: 50, timeout: 300)
      on_exit(fn -> Application.put_env(:assistant_link, AssistantLinkWeb.Connection, config) end)
    end

    test "the service pings, and a Link that answers stays online", %{link: link} = context do
      client = connect_agent(context)

      for _ping <- 1..10, do: assert_receive({:ws, ^client, {:ping, _payload}})

      assert Links.status(link) == :online
      disconnect_last(client, link)
    end

    test "a connection that stops answering is closed and its Link goes offline", %{link: link} = context do
      client = connect_agent(context, pong: false)
      link_id = link.id

      assert_receive {:ws, ^client, {:closed, _code, _reason}}, 1_000
      assert_receive {:link_status, %{link_id: ^link_id, status: :offline}}
    end
  end

  describe "account deletion" do
    test "closes the account's agent connections with account_deleted", %{scope: scope, link: link} = context do
      client = connect_agent(context)
      link_id = link.id
      assert_receive {:link_status, %{link_id: ^link_id, status: :online}}

      :ok = Accounts.delete_account(scope)

      assert_receive {:ws, ^client,
                      {:text,
                       %{
                         "jsonrpc" => "2.0",
                         "method" => "connection.closing",
                         "params" => %{"reason" => "account_deleted"}
                       }}}

      assert_receive {:ws, ^client, {:closed, 1000, "account_deleted"}}
      assert_receive {:link_status, %{link_id: ^link_id, status: :offline}}
      assert {:error, {401, _body}} = open(context.port, "/alp/v1/connect", context.token)
    end

    test "leaves other accounts' agents connected", %{scope: scope} = context do
      other = register_device(%{conn: build_conn()})
      {other_link, other_token} = paired_link_fixture(other.scope)
      :ok = Accounts.subscribe(other.account.id)
      other_client = connect_agent(%{context | token: other_token})

      :ok = Accounts.delete_account(scope)

      refute_receive {:ws, ^other_client, _event}, 200
      assert Links.status(other_link) == :online
      disconnect_last(other_client, other_link)
    end
  end
end
