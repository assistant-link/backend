defmodule AssistantLink.EventsTest do
  use AssistantLink.DataCase, async: true

  import AssistantLink.AccountsFixtures
  import AssistantLink.LinksFixtures

  alias AssistantLink.Accounts
  alias AssistantLink.Events
  alias AssistantLink.Events.Event

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
end
