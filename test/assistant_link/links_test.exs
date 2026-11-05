defmodule AssistantLink.LinksTest do
  use AssistantLink.DataCase, async: true

  import AssistantLink.AccountsFixtures
  import AssistantLink.LinksFixtures

  alias AssistantLink.Accounts
  alias AssistantLink.Assistants
  alias AssistantLink.Events
  alias AssistantLink.Links

  setup do
    scope = user_scope_fixture()
    {link, _token} = paired_link_fixture(scope)
    %{scope: scope, link: link, assistant: Repo.preload(link, :assistant).assistant}
  end

  describe "pair/1" do
    test "tells the account's subscribers the Link is offline, with no last active time", %{scope: scope} do
      {:ok, assistant} = Assistants.create_assistant(scope, %{"name" => "Hermes", "avatar" => "avatar-1"})
      {:ok, link} = Links.create_link(scope, assistant.id, %{})
      {:ok, %{code: code}} = Links.issue_pairing_code(scope, link.id)
      :ok = Accounts.subscribe(scope.account.id)
      link_id = link.id

      refute_received {:link_status, _change}
      {:ok, _paired} = Links.pair(code)

      assert_received {:link_status, %{link_id: ^link_id, status: :offline, last_active_at: nil}}
    end

    test "tells no one when the code is rejected", %{scope: scope} do
      :ok = Accounts.subscribe(scope.account.id)

      assert {:error, :invalid_code} = Links.pair("nope")
      refute_received {:link_status, _change}
    end

    test "starts the Link's cursor at the Assistant's last event", %{scope: scope, assistant: assistant} do
      user_message_fixture(scope, assistant)
      user_message_fixture(scope, assistant)

      {second, _token} = another_paired_link_fixture(scope, assistant)
      assert second.last_read_seq == Repo.reload!(assistant).last_event_seq
      after_pairing = user_message_fixture(scope, assistant)

      assert Repo.reload!(second).last_read_seq == second.last_read_seq
      assert Events.count_deliverable(second.id) == 1
      assert Events.next_deliverable(second.id).id == after_pairing.id
    end

    test "gives each Link of an Assistant its own cursor", %{scope: scope, assistant: assistant, link: first} do
      user_message_fixture(scope, assistant)
      {second, _token} = another_paired_link_fixture(scope, assistant)
      user_message_fixture(scope, assistant)

      assert Events.count_deliverable(first.id) == 2
      assert Events.count_deliverable(second.id) == 1

      :ok = Events.acknowledge(second.id, Events.next_deliverable(second.id).id)

      assert Events.count_deliverable(first.id) == 2
      assert Events.count_deliverable(second.id) == 0
    end
  end

  describe "Events.acknowledge/2" do
    test "never moves the cursor backward", %{scope: scope, assistant: assistant, link: link} do
      first = user_message_fixture(scope, assistant)
      second = user_message_fixture(scope, assistant)

      :ok = Events.acknowledge(link.id, second.id)
      :ok = Events.acknowledge(link.id, first.id)

      assert Repo.reload!(link).last_read_seq == second.seq
      assert Events.count_deliverable(link.id) == 0
    end
  end
end
