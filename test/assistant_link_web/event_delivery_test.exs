defmodule AssistantLinkWeb.EventDeliveryTest do
  # Connections and delivery processes run outside the test process, so the sandbox must be shared.
  use AssistantLinkWeb.ConnCase, async: false

  import AssistantLink.LinksFixtures
  import AssistantLinkWeb.WebSocketClient
  import Ecto.Query, only: [from: 2]

  alias AssistantLink.Accounts
  alias AssistantLink.Delivery
  alias AssistantLink.Events
  alias AssistantLink.Events.Event
  alias AssistantLink.Events.TextMessage
  alias AssistantLink.Links.Link
  alias AssistantLink.Repo

  setup :start_server
  setup :register_device

  setup %{scope: scope, account: account} do
    {link, token} = paired_link_fixture(scope)
    :ok = Accounts.subscribe(account.id)
    %{link: link, token: token, assistant: Repo.preload(link, :assistant).assistant}
  end

  # A test sets a timing with `@tag delivery: [attempt_timeout: ms, retry_wait: ms]`.
  setup context do
    config = Application.fetch_env!(:assistant_link, Delivery)
    Application.put_env(:assistant_link, Delivery, Keyword.merge(config, Map.get(context, :delivery, [])))
    on_exit(fn -> Application.put_env(:assistant_link, Delivery, config) end)
  end

  # The clients end with the test process; no delivery process may outlive the sandbox.
  setup do
    on_exit(fn ->
      refs =
        for {_, pid, _, _} <- DynamicSupervisor.which_children(AssistantLink.Delivery.Supervisor),
            do: Process.monitor(pid)

      for ref <- refs, do: assert_receive({:DOWN, ^ref, _, _, _}, 1_000)
    end)
  end

  defp connect_agent(context, token \\ nil) do
    {:ok, client} = open(context.port, "/alp/v1/connect", token || context.token)
    assert_receive {:ws, ^client, {:text, %{"method" => "connection.ready"}}}
    client
  end

  defp receive_delivery(client) do
    assert_receive {:ws, ^client, {:text, %{"jsonrpc" => "2.0", "method" => "event.deliver"} = request}}, 1_000
    {request["id"], request["params"]}
  end

  defp refute_delivery(client), do: refute_receive({:ws, ^client, {:text, %{"method" => "event.deliver"}}}, 150)

  defp reply(client, message), do: send_text(client, Jason.encode!(Map.put(message, :jsonrpc, "2.0")))

  defp acknowledge(client, id, event_id), do: reply(client, %{id: id, result: %{event_id: event_id}})

  defp answer_error(client, id, error), do: reply(client, %{id: id, error: error})

  defp not_received, do: %{code: -32_001, message: "Not received.", data: %{reason: "not_received"}}

  defp delivery(link) do
    [{pid, _value}] = Registry.lookup(AssistantLink.Delivery.Registry, link.id)
    pid
  end

  # Frames of one connection are handled in order, so its answer to a request means it handled the
  # frames sent before; the delivery process has then got what they reported once it answers.
  defp settle(client, link) do
    :ok = send_text(client, Jason.encode!(%{jsonrpc: "2.0", id: 1_000, method: "a.b"}))
    assert_receive {:ws, ^client, {:text, %{"id" => 1_000, "error" => %{"code" => -32_601}}}}
    link |> delivery() |> :sys.get_state()
  end

  defp fail_round(client, link) do
    {id, _params} = receive_delivery(client)
    answer_error(client, id, not_received())
    settle(client, link)
  end

  defp retry_now(link), do: send(delivery(link), :retry)

  defp cursor(link), do: Repo.reload!(link).last_read_seq

  defp close_and_wait(client, link) do
    ref = link |> delivery() |> Process.monitor()
    close(client)
    assert_receive {:DOWN, ^ref, :process, _pid, :normal}
  end

  describe "event.deliver" do
    test "sends a stored message as a request with the event as params",
         %{scope: scope, assistant: assistant} = context do
      event = user_message_fixture(scope, assistant)
      client = connect_agent(context)

      assert_receive {:ws, ^client, {:text, request}}, 1_000

      assert request == %{
               "jsonrpc" => "2.0",
               "id" => 1,
               "method" => "event.deliver",
               "params" => %{
                 "id" => event.id,
                 "type" => "text_message",
                 "created_at" => DateTime.to_iso8601(event.inserted_at),
                 "deleted" => false,
                 "text_message" => %{"text" => "Hi"}
               }
             }

      assert {:ok, _created_at, 0} = DateTime.from_iso8601(request["params"]["created_at"])
    end

    test "sends an event without content when its text was deleted", %{scope: scope, assistant: assistant} = context do
      event = user_message_fixture(scope, assistant)
      Repo.delete!(Repo.get!(TextMessage, event.id))
      client = connect_agent(context)

      assert {_id, params} = receive_delivery(client)

      assert params == %{
               "id" => event.id,
               "type" => "text_message",
               "created_at" => DateTime.to_iso8601(event.inserted_at),
               "deleted" => true
             }
    end

    test "keeps one in flight, numbers each side's requests on its own, and sends the next after the acknowledgement",
         %{scope: scope, assistant: assistant} = context do
      first = user_message_fixture(scope, assistant, "a")
      second = user_message_fixture(scope, assistant, "b")
      client = connect_agent(context)

      assert {1, %{"id" => first_id}} = receive_delivery(client)
      assert first_id == first.id
      refute_delivery(client)

      :ok = send_text(client, Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "a.b"}))
      assert_receive {:ws, ^client, {:text, %{"id" => 1, "error" => %{"code" => -32_601}}}}

      acknowledge(client, 1, first.id)

      assert {2, %{"id" => second_id}} = receive_delivery(client)
      assert second_id == second.id
    end

    test "sends a message stored while the Link is online, but not the agent's own",
         %{scope: scope, assistant: assistant, link: link} = context do
      client = connect_agent(context)
      refute_delivery(client)

      {:ok, _event, :created} = Events.create_assistant_message(link, %{"text" => "Done."})
      user_message_fixture(scope, assistant)

      assert {1, %{"text_message" => %{"text" => "Hi"}}} = receive_delivery(client)
    end

    test "answers to a request that is not pending change nothing", %{scope: scope, assistant: assistant} = context do
      user_message_fixture(scope, assistant)
      client = connect_agent(context)
      assert {1, _params} = receive_delivery(client)

      answer_error(client, 77, not_received())
      reply(client, %{id: "x", result: true})

      assert %{attempt: %{}, failed: []} = settle(client, context.link)
      refute_delivery(client)
    end
  end

  describe "acknowledgement" do
    test "advances the cursor and marks the message delivered",
         %{scope: scope, assistant: assistant, link: link} = context do
      event = user_message_fixture(scope, assistant)
      client = connect_agent(context)
      {id, _params} = receive_delivery(client)

      acknowledge(client, id, event.id)

      event_id = event.id
      assert_receive {:event_updated, %Event{id: ^event_id, delivered_at: %DateTime{}}}
      settle(client, link)
      assert cursor(link) == event.seq
    end

    test "is honored on another connection", %{scope: scope, assistant: assistant, link: link} = context do
      older = connect_agent(context)
      newer = connect_agent(context)
      event = user_message_fixture(scope, assistant)
      {_id, _params} = receive_delivery(newer)
      refute_delivery(older)

      acknowledge(older, 99, event.id)

      settle(older, link)
      assert cursor(link) == event.seq
    end

    test "by another Link first leaves delivered_at and sends event.updated once",
         %{scope: scope, assistant: assistant, link: link} = context do
      {link_two, token_two} = another_paired_link_fixture(scope, assistant)
      event = user_message_fixture(scope, assistant)
      one = connect_agent(context)
      two = connect_agent(context, token_two)
      {id_one, _params} = receive_delivery(one)
      {id_two, _params} = receive_delivery(two)

      acknowledge(one, id_one, event.id)
      event_id = event.id
      assert_receive {:event_updated, %Event{id: ^event_id, delivered_at: delivered_at}}
      settle(one, link)

      acknowledge(two, id_two, event.id)
      settle(two, link_two)

      assert cursor(link_two) == event.seq
      assert Repo.get!(Event, event.id).delivered_at == delivered_at
      refute_receive {:event_updated, _event}
    end

    test "ignores an event_id that is not usable and keeps the connection open",
         %{scope: scope, assistant: assistant, link: link} = context do
      older = user_message_fixture(scope, assistant, "before pairing")
      {link_two, token_two} = another_paired_link_fixture(scope, assistant)
      {other_link, _token} = paired_link_fixture(scope, "Muse")
      foreign = user_message_fixture(scope, Repo.preload(other_link, :assistant).assistant)
      link_created = Repo.get_by!(Event, link_id: link_two.id, type: :link_created)
      {:ok, own, :created} = Events.create_assistant_message(link_two, %{"text" => "Done."})
      start = cursor(link_two)
      client = connect_agent(context, token_two)
      refute_delivery(client)

      unusable = [
        Ecto.UUID.generate(),
        "not-a-uuid",
        String.duplicate("a", 16),
        12_345,
        nil,
        foreign.id,
        link_created.id,
        own.id,
        older.id
      ]

      for event_id <- unusable, do: acknowledge(client, 5, event_id)

      settle(client, link_two)
      assert cursor(link_two) == start
      assert Repo.aggregate(from(e in Event, where: not is_nil(e.delivered_at)), :count) == 0
      assert cursor(link) == 1
    end
  end

  describe "errors and duplicates" do
    for {name, error} <- [
          {"-32601", %{code: -32_601, message: "Method not found: event.deliver"}},
          {"-32001 not_received", %{code: -32_001, message: "Not received.", data: %{reason: "not_received"}}},
          {"another error", %{code: -32_000, message: "Busy."}}
        ] do
      @tag delivery: [retry_wait: 50]
      test "#{name} fails the attempt; the event is sent again with the same id",
           %{scope: scope, assistant: assistant} = context do
        event = user_message_fixture(scope, assistant)
        client = connect_agent(context)
        {id, params} = receive_delivery(client)

        answer_error(client, id, unquote(Macro.escape(error)))

        assert {next_id, ^params} = receive_delivery(client)
        assert next_id == id + 1
        assert params["id"] == event.id
        assert cursor(context.link) == 1
      end
    end

    @tag delivery: [attempt_timeout: 50, retry_wait: 50]
    test "no response within the timeout fails the attempt, and a late result is still honored",
         %{scope: scope, assistant: assistant, link: link} = context do
      event = user_message_fixture(scope, assistant)
      client = connect_agent(context)
      {id, params} = receive_delivery(client)

      assert {next_id, ^params} = receive_delivery(client)
      assert next_id == id + 1
      assert cursor(link) == 1

      acknowledge(client, id, event.id)

      settle(client, link)
      assert cursor(link) == event.seq
    end

    test "an error answer to an earlier attempt fails nothing", %{scope: scope, assistant: assistant} = context do
      older = connect_agent(context)
      newer = connect_agent(context)
      user_message_fixture(scope, assistant)
      {id, _params} = receive_delivery(newer)

      answer_error(newer, id, not_received())
      assert {_id, _params} = receive_delivery(older)
      answer_error(newer, id, not_received())

      assert %{attempt: %{}, failed: [_newer]} = settle(newer, context.link)
    end
  end

  describe "retry target and backoff" do
    test "goes to the next-newest connection that has not failed the event",
         %{scope: scope, assistant: assistant} = context do
      oldest = connect_agent(context)
      middle = connect_agent(context)
      newest = connect_agent(context)
      event = user_message_fixture(scope, assistant)

      states =
        for client <- [newest, middle, oldest] do
          {_id, %{"id" => event_id}} = receive_delivery(client)
          assert event_id == event.id
          answer_error(client, 1, not_received())
          settle(client, context.link)
        end

      assert [%{attempt: %{}}, %{attempt: %{}}, %{attempt: nil, wait: 30_000}] = states
    end

    test "a closed connection fails the attempt", %{scope: scope, assistant: assistant} = context do
      older = connect_agent(context)
      newer = connect_agent(context)
      user_message_fixture(scope, assistant)
      {_id, _params} = receive_delivery(newer)

      :ok = close(newer)

      assert {_id, _params} = receive_delivery(older)
    end

    test "waits 30 seconds when every connection failed, doubling per failed round up to 5 minutes",
         %{scope: scope, assistant: assistant, link: link} = context do
      user_message_fixture(scope, assistant)
      client = connect_agent(context)

      waits =
        for _round <- 1..6 do
          %{wait: wait, retry: timer} = fail_round(client, link)
          assert Process.read_timer(timer) in (wait - 1_000)..wait
          retry_now(link)
          wait
        end

      assert waits == [30_000, 60_000, 120_000, 240_000, 300_000, 300_000]
    end

    test "a new connection resets the wait and starts a round at once",
         %{scope: scope, assistant: assistant, link: link} = context do
      user_message_fixture(scope, assistant)
      first = connect_agent(context)
      fail_round(first, link)
      retry_now(link)
      assert %{wait: 60_000} = fail_round(first, link)

      second = connect_agent(context)

      assert {id, params} = receive_delivery(second)
      assert %{wait: nil, retry: nil} = settle(second, link)
      answer_error(second, id, not_received())

      assert {id, ^params} = receive_delivery(first)
      answer_error(first, id, not_received())

      assert %{wait: 30_000} = settle(first, link)
    end
  end

  describe "catch-up" do
    test "sends every message after the cursor in order, and only the unacknowledged ones after a reconnect",
         %{scope: scope, assistant: assistant, link: link} = context do
      [a, b, c] = for text <- ["a", "b", "c"], do: user_message_fixture(scope, assistant, text)
      client = connect_agent(context)

      assert {id, %{"id" => first}} = receive_delivery(client)
      assert first == a.id
      acknowledge(client, id, a.id)
      assert {id, %{"id" => second}} = receive_delivery(client)
      assert second == b.id
      acknowledge(client, id, b.id)
      assert {_id, %{"id" => third}} = receive_delivery(client)
      assert third == c.id
      close_and_wait(client, link)

      again = connect_agent(context)

      assert {1, %{"id" => resumed}} = receive_delivery(again)
      assert resumed == c.id
    end

    test "does not send what was stored before pairing, and sends what was stored after",
         %{scope: scope, assistant: assistant} = context do
      user_message_fixture(scope, assistant, "before")
      {_link_two, token_two} = another_paired_link_fixture(scope, assistant)
      after_pairing = user_message_fixture(scope, assistant, "after")

      client = connect_agent(context, token_two)

      assert {_id, %{"id" => id}} = receive_delivery(client)
      assert id == after_pairing.id
      refute_delivery(client)
    end
  end

  describe "delivery process" do
    test "is one per Link and ends with its last connection", %{link: link} = context do
      one = connect_agent(context)
      two = connect_agent(context)

      assert [_one_process] = Registry.lookup(AssistantLink.Delivery.Registry, link.id)
      ref = link |> delivery() |> Process.monitor()
      :ok = close(one)
      settle(two, link)
      :ok = close(two)

      assert_receive {:DOWN, ^ref, :process, _pid, :normal}
    end

    test "is started again for an open connection after a crash and catches up",
         %{scope: scope, assistant: assistant, link: link} = context do
      client = connect_agent(context)
      crashed = delivery(link)
      ref = Process.monitor(crashed)
      Process.exit(crashed, :kill)
      assert_receive {:DOWN, ^ref, :process, _pid, :killed}

      event = user_message_fixture(scope, assistant)

      # The connection starts the process again, which then reads the stored message.
      assert {id, %{"id" => event_id}} = receive_delivery(client)
      assert event_id == event.id
      acknowledge(client, id, event.id)
      assert_receive {:event_updated, %Event{delivered_at: %DateTime{}}}
      assert delivery(link) != crashed
    end

    test "does not deliver to a Link of a deleted account",
         %{scope: scope, assistant: assistant, link: link} = context do
      user_message_fixture(scope, assistant)
      client = connect_agent(context)
      {_id, _params} = receive_delivery(client)

      ref = link |> delivery() |> Process.monitor()
      :ok = Accounts.delete_account(scope)

      assert_receive {:ws, ^client, {:closed, 1000, "account_deleted"}}
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}
      assert Events.next_deliverable(link.id) == nil
      assert Events.count_deliverable(link.id) == 0
      assert Repo.get!(Link, link.id).last_read_seq == 1
    end
  end
end
