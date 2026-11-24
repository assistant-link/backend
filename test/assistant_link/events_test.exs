defmodule AssistantLink.EventsTest do
  use AssistantLink.DataCase, async: true

  import AssistantLink.AccountsFixtures
  import AssistantLink.LinksFixtures

  alias AssistantLink.Accounts
  alias AssistantLink.Events
  alias AssistantLink.Events.Event
  alias AssistantLink.Events.TextMessage

  setup do
    scope = user_scope_fixture()
    {link, _token} = paired_link_fixture(scope)
    :ok = Accounts.subscribe(scope.account.id)
    %{scope: scope, link: link}
  end

  defp user_message(scope, link) do
    params = %{"text" => "Hi", "idempotency_key" => Ecto.UUID.generate(version: 7)}
    {:ok, event, :created} = Events.create_text_message(scope, link.assistant_id, params)
    event
  end

  describe "mark_delivered/2" do
    test "sets delivered_at once and sends one event_updated", %{scope: scope, link: link} do
      event = user_message(scope, link)
      account_id = scope.account.id
      id = event.id

      assert :ok = Events.mark_delivered(account_id, id)

      assert_receive {:event_updated,
                      %Event{id: ^id, delivered_at: %DateTime{} = delivered_at, text_message: %{text: "Hi"}}}

      assert :ok = Events.mark_delivered(account_id, id)
      refute_receive {:event_updated, _event}

      assert Repo.get!(Event, id).delivered_at == delivered_at
    end

    test "ignores events that are not the account's user messages", %{scope: scope, link: link} do
      other_scope = user_scope_fixture()
      {other_link, _token} = paired_link_fixture(other_scope)
      other_message = user_message(other_scope, other_link)
      link_created = Repo.one!(from e in Event, where: e.link_id == ^link.id)

      assert :ok = Events.mark_delivered(scope.account.id, other_message.id)
      assert :ok = Events.mark_delivered(scope.account.id, link_created.id)
      assert :ok = Events.mark_delivered(scope.account.id, Ecto.UUID.generate())

      refute_receive {:event_updated, _event}
      assert Repo.aggregate(from(e in Event, where: not is_nil(e.delivered_at)), :count) == 0
    end
  end

  test "acknowledge/2 advances nothing and marks nothing delivered for a deleted account", %{scope: scope, link: link} do
    event = user_message(scope, link)
    :ok = Accounts.delete_account(scope)

    assert :ok = Events.acknowledge(link.id, event.id)

    refute_receive {:event_updated, _event}
    assert Repo.get!(AssistantLink.Links.Link, link.id).last_read_seq == 1
    assert Repo.get!(Event, event.id).delivered_at == nil
  end

  test "create_text_message/3 sends event_created once, and not for a repeated or rejected message", %{
    scope: scope,
    link: link
  } do
    params = %{"text" => "Hi", "idempotency_key" => Ecto.UUID.generate(version: 7)}
    {:ok, %{id: id}, :created} = Events.create_text_message(scope, link.assistant_id, params)
    assert_receive {:event_created, %Event{id: ^id, text_message: %{text: "Hi"}}}

    assert {:ok, _event, :existing} = Events.create_text_message(scope, link.assistant_id, params)
    empty = %{"text" => "", "idempotency_key" => Ecto.UUID.generate(version: 7)}
    assert {:error, :text_empty} = Events.create_text_message(scope, link.assistant_id, empty)
    refute_receive {:event_created, _event}
  end

  test "create_text_message/3 rejects a raw 16-byte binary as the idempotency key", %{scope: scope, link: link} do
    raw = Ecto.UUID.bingenerate()
    params = %{"text" => "Hi", "idempotency_key" => raw}
    assert {:error, :invalid_params} = Events.create_text_message(scope, link.assistant_id, params)
  end

  describe "reply_to" do
    defp reply(scope, link, reply_to, key \\ Ecto.UUID.generate(version: 7)) do
      params = %{"text" => "Yes", "idempotency_key" => key, "reply_to" => reply_to}
      Events.create_text_message(scope, link.assistant_id, params)
    end

    test "stores a reply to a user's or the Assistant's text message of the Assistant", %{scope: scope, link: link} do
      question = user_message(scope, link)

      {:ok, answer, :created} =
        Events.create_assistant_message(link, %{"text" => "Which one?", "reply_to" => question.id})

      assert {:ok, %Event{reply_to: reply_to} = event, :created} = reply(scope, link, answer.id)
      assert reply_to == answer.id
      assert Repo.get!(Event, event.id).reply_to == answer.id
      assert Repo.get!(Event, answer.id).reply_to == question.id
    end

    test "is nil when omitted or null", %{scope: scope, link: link} do
      assert %Event{reply_to: nil} = user_message(scope, link)
      assert {:ok, %Event{reply_to: nil}, :created} = reply(scope, link, nil)
    end

    test "accepts the id of a deleted text message", %{scope: scope, link: link} do
      question = user_message(scope, link)
      Repo.delete!(Repo.get!(TextMessage, question.id))

      assert {:ok, %Event{reply_to: reply_to}, :created} = reply(scope, link, question.id)
      assert reply_to == question.id
    end

    test "rejects a call event, a missing or malformed id, and another Assistant's message, storing nothing", %{
      scope: scope,
      link: link
    } do
      call_params = %{"type" => "call_started", "idempotency_key" => Ecto.UUID.generate(version: 7)}
      {:ok, call, :created} = Events.create_call_event(scope, link.assistant_id, call_params)
      link_created = Repo.one!(from e in Event, where: e.link_id == ^link.id and e.type == :link_created)
      {other_link, _token} = paired_link_fixture(scope, "Muse")
      other = user_message(scope, other_link)
      other_account_scope = user_scope_fixture()
      {other_account_link, _token} = paired_link_fixture(other_account_scope)
      other_account = user_message(other_account_scope, other_account_link)
      count = Repo.aggregate(Event, :count)

      for reply_to <- [
            call.id,
            link_created.id,
            other.id,
            other_account.id,
            Ecto.UUID.generate(),
            "not-a-uuid",
            Ecto.UUID.bingenerate(),
            5
          ] do
        assert {:error, :invalid_params} = reply(scope, link, reply_to)

        assert {:error, :invalid_params} =
                 Events.create_assistant_message(link, %{"text" => "Hi", "reply_to" => reply_to})
      end

      assert Repo.aggregate(Event, :count) == count
    end

    test "a repeated key must repeat reply_to", %{scope: scope, link: link} do
      first = user_message(scope, link)
      second = user_message(scope, link)
      key = Ecto.UUID.generate(version: 7)
      {:ok, %{id: id}, :created} = reply(scope, link, first.id, key)

      assert {:ok, %Event{id: ^id}, :existing} = reply(scope, link, first.id, key)
      assert {:ok, %Event{id: ^id}, :existing} = reply(scope, link, String.upcase(first.id), key)
      assert {:error, :idempotency_key_conflict} = reply(scope, link, second.id, key)
      assert {:error, :idempotency_key_conflict} = reply(scope, link, nil, key)

      plain_key = Ecto.UUID.generate(version: 7)
      {:ok, _event, :created} = reply(scope, link, nil, plain_key)
      assert {:error, :idempotency_key_conflict} = reply(scope, link, first.id, plain_key)
    end

    test "a repeated agent key must repeat reply_to", %{scope: scope, link: link} do
      question = user_message(scope, link)
      params = %{"text" => "Yes", "idempotency_key" => Ecto.UUID.generate(version: 7), "reply_to" => question.id}
      {:ok, %{id: id}, :created} = Events.create_assistant_message(link, params)

      assert {:ok, %Event{id: ^id}, :existing} = Events.create_assistant_message(link, params)

      assert {:error, :idempotency_key_conflict} =
               Events.create_assistant_message(link, Map.delete(params, "reply_to"))
    end
  end
end
