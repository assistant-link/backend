defmodule AssistantLinkWeb.AppConnectionTest do
  # Connections run in the server's processes and Presence's, which share the test's database
  # connection only in the sandbox's shared mode.
  use AssistantLinkWeb.ConnCase, async: false

  import AssistantLink.LinksFixtures
  import AssistantLinkWeb.WebSocketClient

  alias AssistantLink.Accounts
  alias AssistantLink.Assistants
  alias AssistantLink.Calls
  alias AssistantLink.Events
  alias AssistantLink.Links

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
    assert_receive {:ws, ^app, {:text, %{"method" => "link.status", "params" => %{"status" => "offline"}}}}

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

  test "sends link.status idle when the last agent connection of a Link with a webhook closes", %{
    app: app,
    scope: scope,
    port: port
  } do
    {link, token} = paired_link_fixture(scope)
    link_id = link.id
    assert_receive {:ws, ^app, {:text, %{"method" => "link.status", "params" => %{"status" => "offline"}}}}
    {:ok, _link} = Links.put_webhook(link, %{"url" => "https://a.test/hook"})
    assert_receive {:ws, ^app, {:text, %{"method" => "link.status", "params" => %{"status" => "idle"}}}}

    {:ok, agent} = open(port, "/alp/v1/connect", token)
    assert_receive {:ws, ^app, {:text, %{"method" => "link.status", "params" => %{"status" => "online"}}}}

    :ok = close(agent)

    assert_receive {:ws, ^app,
                    {:text, %{"method" => "link.status", "params" => %{"link_id" => ^link_id, "status" => "idle"}}}}

    :ok = close(app)
  end

  test "sends link.status idle when a wake email is confirmed and when the last agent connection closes", %{
    app: app,
    scope: scope,
    port: port
  } do
    {link, token} = paired_link_fixture(scope)
    link_id = link.id
    assert_receive {:ws, ^app, {:text, %{"method" => "link.status", "params" => %{"status" => "offline"}}}}
    {:ok, link} = Links.put_wake_email(link, %{"address" => "hermes@example.com"})
    {:ok, _link} = Links.confirm_wake_email(link.id, "hermes@example.com")
    assert_receive {:ws, ^app, {:text, %{"method" => "link.status", "params" => %{"status" => "idle"}}}}

    {:ok, agent} = open(port, "/alp/v1/connect", token)
    assert_receive {:ws, ^app, {:text, %{"method" => "link.status", "params" => %{"status" => "online"}}}}

    :ok = close(agent)

    assert_receive {:ws, ^app,
                    {:text, %{"method" => "link.status", "params" => %{"link_id" => ^link_id, "status" => "idle"}}}}

    :ok = close(app)
  end

  test "sends link.status offline when a Link is paired, before any agent connects", %{app: app, scope: scope} do
    {:ok, assistant} = Assistants.create_assistant(scope, %{"name" => "Hermes", "avatar" => "avatar-1"})
    {:ok, link} = Links.create_link(scope, assistant.id, %{})
    {:ok, %{code: code}} = Links.issue_pairing_code(scope, link.id)
    link_id = link.id

    {:ok, _paired} = Links.pair(code)

    assert_receive {:ws, ^app,
                    {:text,
                     %{
                       "jsonrpc" => "2.0",
                       "method" => "link.status",
                       "params" => %{"link_id" => ^link_id, "status" => "offline", "last_active_at" => nil}
                     }}}

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
    setup %{app: app, scope: scope} do
      {link, token} = paired_link_fixture(scope)
      assert_receive {:ws, ^app, {:text, %{"method" => "link.status", "params" => %{"status" => "offline"}}}}
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

    test "sends reply_to in event.created for a reply", %{app: app, scope: scope, link: link} do
      {:ok, %{id: question_id}, :created} = Events.create_text_message(scope, link.assistant_id, message_params())
      assert_receive {:ws, ^app, {:text, %{"method" => "event.created", "params" => %{"event" => question}}}}
      refute Map.has_key?(question, "reply_to")

      params = Map.put(message_params(), "reply_to", question_id)
      {:ok, _event, :created} = Events.create_text_message(scope, link.assistant_id, params)

      assert_receive {:ws, ^app,
                      {:text, %{"method" => "event.created", "params" => %{"event" => %{"reply_to" => ^question_id}}}}}

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

    test "sends a call's voice_call event and its transcript entries", %{app: app, scope: scope, link: link} do
      {:ok, %{id: call_id}, _call_started} = Calls.start_call(scope, link.assistant_id, %{})

      assert_receive {:ws, ^app,
                      {:text,
                       %{
                         "method" => "event.created",
                         "params" => %{"event" => %{"type" => "voice_call", "voice_call" => %{"call_id" => ^call_id}}}
                       }}}

      assert_receive {:ws, ^app,
                      {:text, %{"method" => "event.created", "params" => %{"event" => %{"type" => "call_started"}}}}}

      params = %{"speaker" => "assistant", "text" => "Hello", "started_at" => "2026-11-25T10:00:00Z"}
      {:ok, %{id: id}, :created} = Calls.create_transcript_entry(scope, link.assistant_id, call_id, params)

      assert_receive {:ws, ^app, {:text, %{"method" => "call.transcript_entry", "params" => params}}}

      assert params == %{
               "transcript_entry" => %{
                 "id" => id,
                 "call_id" => call_id,
                 "seq" => 1,
                 "speaker" => "assistant",
                 "text" => "Hello",
                 "started_at" => "2026-11-25T10:00:00.000000Z",
                 "ended_at" => nil
               }
             }

      {:ok, _call} = Calls.end_call(scope, link.assistant_id, call_id)

      assert_receive {:ws, ^app,
                      {:text,
                       %{
                         "method" => "event.updated",
                         "params" => %{"event" => %{"type" => "voice_call", "voice_call" => %{"ended_at" => ended_at}}}
                       }}}

      assert ended_at
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

  describe "activity" do
    setup %{app: app, scope: scope} do
      {link, token} = paired_link_fixture(scope)
      assert_receive {:ws, ^app, {:text, %{"method" => "link.status", "params" => %{"status" => "offline"}}}}
      %{link: link, token: token, agent: put_req_header(build_conn(), "authorization", "Bearer " <> token)}
    end

    defp connect_agent(%{app: app, port: port, token: token}) do
      {:ok, agent} = open(port, "/alp/v1/connect", token)
      assert_receive {:ws, ^agent, {:text, %{"method" => "connection.caught_up"}}}
      assert_receive {:ws, ^app, {:text, %{"method" => "link.status", "params" => %{"status" => "online"}}}}
      agent
    end

    # The agent connection handles messages in order, so once it answers, it has taken the activity.
    defp sync(agent) do
      :ok = send_text(agent, Jason.encode!(%{jsonrpc: "2.0", id: "sync", method: "sync"}))
      assert_receive {:ws, ^agent, {:text, %{"id" => "sync"}}}
    end

    defp set_activity(%{agent: conn, app: app, link: %{id: link_id}}, agent, text) do
      assert conn |> put(~p"/alp/v1/link/activity", %{"text" => text}) |> json_response(200)

      assert_receive {:ws, ^app,
                      {:text,
                       %{
                         "jsonrpc" => "2.0",
                         "method" => "link.activity",
                         "params" => %{"link_id" => ^link_id, "activity" => ^text}
                       }}}

      sync(agent)
    end

    defp assert_cleared(%{app: app, link: %{id: link_id}}) do
      assert_receive {:ws, ^app,
                      {:text, %{"method" => "link.activity", "params" => %{"link_id" => ^link_id, "activity" => nil}}}}
    end

    test "sends link.activity when the agent sets and clears it, and lists it with the Link", context do
      agent = connect_agent(context)

      set_activity(context, agent, "Searching the code…")
      assert [%{"activity" => "Searching the code…"}] = listed_links(context)

      assert context.agent |> delete(~p"/alp/v1/link/activity") |> response(204)
      assert_cleared(context)
      sync(agent)
      assert [%{"activity" => nil}] = listed_links(context)

      :ok = close(agent)
    end

    test "clears it when the agent sends a message", context do
      agent = connect_agent(context)
      set_activity(context, agent, "Typing…")

      assert context.agent |> post(~p"/alp/v1/messages", %{"text" => "Done."}) |> json_response(201)

      assert_cleared(context)
      sync(agent)
      assert Links.activity(context.link) == nil
      :ok = close(agent)
    end

    test "keeps it while a connection stays, and clears it when the last one closes", %{app: app} = context do
      first = connect_agent(context)
      set_activity(context, first, "Filing an issue…")
      {:ok, second} = open(context.port, "/alp/v1/connect", context.token)
      assert_receive {:ws, ^second, {:text, %{"method" => "connection.caught_up"}}}

      :ok = close(first)
      refute_receive {:ws, ^app, {:text, %{"method" => "link.activity"}}}, 200
      assert Links.activity(context.link) == "Filing an issue…"

      :ok = close(second)
      assert_receive {:ws, ^app, {:text, %{"method" => "link.status", "params" => %{"status" => "offline"}}}}
      assert_cleared(context)
      assert Links.activity(context.link) == nil
      :ok = close(app)
    end
  end

  defp listed_links(%{credential: credential}) do
    [%{"links" => links}] =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> credential)
      |> get(~p"/api/v1/assistants")
      |> json_response(200)
      |> Map.fetch!("assistants")

    links
  end

  test "sends assistant.updated when the agent renames its Assistant or sets its platform", %{
    app: app,
    scope: scope,
    port: port
  } do
    {link, token} = paired_link_fixture(scope)
    assistant_id = link.assistant_id
    {:ok, agent} = open(port, "/alp/v1/connect", token)
    assert_receive {:ws, ^agent, {:text, %{"method" => "connection.caught_up"}}}

    assert build_conn()
           |> put_req_header("authorization", "Bearer " <> token)
           |> patch(~p"/alp/v1/assistant", %{"name" => "Athena", "platform" => "Muse"})
           |> json_response(200)

    assert_receive {:ws, ^app, {:text, %{"jsonrpc" => "2.0", "method" => "assistant.updated"} = notice}}
    refute Map.has_key?(notice, "id")
    assert notice["params"] == %{"assistant" => %{"id" => assistant_id, "name" => "Athena", "platform" => "muse"}}

    :ok = send_text(agent, Jason.encode!(%{jsonrpc: "2.0", id: "sync", method: "sync"}))
    assert_receive {:ws, ^agent, {:text, %{"id" => "sync"}}}
    refute_received {:ws, ^agent, {:text, %{"method" => "assistant.updated"}}}

    for client <- [agent, app], do: :ok = close(client)
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
