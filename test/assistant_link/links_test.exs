defmodule AssistantLink.LinksTest do
  use AssistantLink.DataCase, async: true

  import AssistantLink.AccountsFixtures
  import AssistantLink.LinksFixtures

  alias AssistantLink.Events

  setup do
    scope = user_scope_fixture()
    {link, _token} = paired_link_fixture(scope)
    %{scope: scope, link: link, assistant: Repo.preload(link, :assistant).assistant}
  end

  describe "pair/1" do
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
