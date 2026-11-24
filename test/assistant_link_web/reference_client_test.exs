defmodule AssistantLinkWeb.ReferenceClientTest do
  # The client talks to a real server, whose processes share the test's database connection only in
  # the sandbox's shared mode.
  use AssistantLinkWeb.ConnCase, async: false

  import AssistantLinkWeb.WebSocketClient, only: [start_server: 1]

  alias AssistantLink.Accounts
  alias AssistantLink.Assistants
  alias AssistantLink.Links

  @client Path.expand("../../docs/alp/client.mjs", __DIR__)

  setup :start_server
  setup :register_device

  setup %{scope: scope} do
    {:ok, assistant} = Assistants.create_assistant(scope, %{"name" => "Hermes", "avatar" => "avatar-1"})
    {:ok, link} = Links.create_link(scope, assistant.id, %{})
    {:ok, %{code: code}} = Links.issue_pairing_code(scope, link.id)
    test = self()

    Req.Test.stub(AssistantLinkWeb.Webhook, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:webhook, Plug.Conn.get_req_header(conn, "authorization"), Jason.decode!(body)})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    %{assistant: assistant, link: link, code: code}
  end

  # Runs one step of the client and returns the JSON it prints. It must never print the token.
  defp run!(args, env \\ []) do
    {0, output} = run(args, env)
    output
  end

  defp run(args, env \\ []) do
    {output, status} = System.cmd(node!(), [@client | args], env: env, stderr_to_stdout: true)
    refute output =~ "alt_"
    {status, Jason.decode!(output)}
  end

  defp node!, do: System.find_executable("node") || flunk("Node.js 22 or later must be installed")

  defp user_sends(conn, assistant, params) do
    params = Map.put(params, "idempotency_key", Ecto.UUID.generate(version: 7))
    path = if params["type"], do: "call_events", else: "messages"
    conn |> post("/api/v1/assistants/#{assistant.id}/#{path}", params) |> json_response(201)
  end

  defp next_line(port) do
    assert_receive {^port, {:data, {:eol, line}}}, 5_000
    refute line =~ "alt_"
    Jason.decode!(line)
  end

  @tag :tmp_dir
  test "the reference client follows the protocol-only journey of install.md", context do
    %{conn: conn, port: port, code: code, link: link, assistant: assistant, tmp_dir: dir} = context
    store = Path.join(dir, "hermes.json")
    link_id = link.id

    assert run!(["pair", "http://localhost:#{port}", code, store]) == %{
             "link_id" => link_id,
             "assistant_name" => "Hermes"
           }

    assert Bitwise.band(File.stat!(store).mode, 0o777) == 0o600
    assert %{"link_id" => ^link_id, "unread_count" => 0} = run!(["status", store])
    assert run!(["platform", store, "Instinct"]) == %{"name" => "Hermes", "platform" => "instinct"}

    assert run!(["webhook", store, "https://agent.test/wake"], [{"AL_WEBHOOK_AUTHORIZATION", "Bearer s3cret"}]) ==
             %{"webhook" => %{"url" => "https://agent.test/wake", "authorization" => "Bearer ***"}}

    user_sends(conn, assistant, %{"text" => "Hi"})
    assert_receive {:webhook, ["Bearer s3cret"], %{"type" => "wake", "link_id" => ^link_id}}, 1_000
    user_sends(conn, assistant, %{"type" => "call_started"})
    assert %{"unread_count" => 2} = run!(["status", store])

    :ok = Accounts.subscribe(context.account.id)

    client =
      Port.open({:spawn_executable, node!()}, [:binary, :exit_status, line: 65_536, args: [@client, "answer", store]])

    assert %{"ready" => ^link_id} = next_line(client)
    assert %{"event" => "text_message", "text" => "Hi"} = next_line(client)
    assert %{"replied" => "You said: Hi"} = next_line(client)
    assert %{"event" => "call_started"} = next_line(client)
    assert %{"caught_up" => true, "on_call" => true} = next_line(client)

    user_sends(conn, assistant, %{"text" => "What time is it?", "via" => "voice"})
    assert %{"event" => "text_message", "text" => "What time is it?", "via" => "voice"} = next_line(client)
    assert %{"replied" => "You said: What time is it?"} = next_line(client)

    user_sends(conn, assistant, %{"type" => "call_ended"})
    assert %{"event" => "call_ended"} = next_line(client)
    assert_receive {^client, {:exit_status, 0}}, 5_000
    assert_receive {:link_status, %{link_id: ^link_id, status: :idle}}, 5_000

    assert %{"unread_count" => 0} = run!(["status", store])

    replies =
      conn
      |> get("/api/v1/assistants/#{assistant.id}/events")
      |> json_response(200)
      |> Map.fetch!("events")
      |> Enum.filter(&(&1["sender"] == "assistant"))
      |> Enum.map(& &1["text_message"]["text"])

    assert Enum.sort(replies) == ["You said: Hi", "You said: What time is it?"]
  end

  @tag :tmp_dir
  test "pairing into a store file that exists fails before the code is used", context do
    %{port: port, code: code, tmp_dir: dir} = context
    service = "http://localhost:#{port}"
    taken = Path.join(dir, "taken.json")
    File.write!(taken, "another Link")

    assert {1, %{"error" => %{"store" => "EEXIST"}}} = run(["pair", service, code, taken])
    assert File.read!(taken) == "another Link"
    assert %{"assistant_name" => "Hermes"} = run!(["pair", service, code, Path.join(dir, "hermes.json")])
  end

  @tag :tmp_dir
  test "a failed pairing leaves no store file behind", context do
    %{port: port, code: code, tmp_dir: dir} = context
    service = "http://localhost:#{port}"
    store = Path.join(dir, "hermes.json")
    run!(["pair", service, code, Path.join(dir, "first.json")])

    assert {1, %{"error" => _}} = run(["pair", service, code, store])
    refute File.exists?(store)
  end
end
