defmodule AssistantLink.LinksWakeEmailTest do
  use AssistantLink.DataCase, async: true

  import AssistantLink.AccountsFixtures
  import AssistantLink.LinksFixtures

  alias AssistantLink.Accounts
  alias AssistantLink.Links
  alias AssistantLink.Links.Link

  setup do
    scope = user_scope_fixture()
    {link, _token} = paired_link_fixture(scope)
    %{scope: scope, link: link}
  end

  test "sets an unconfirmed address, confirms it, and clears it", %{link: link} do
    assert Links.show_wake_email(link) == nil

    {:ok, link} = Links.put_wake_email(link, %{"address" => " agent@example.com "})
    assert Links.show_wake_email(link) == %{address: "agent@example.com", confirmed: false}

    assert {:ok, link} = Links.confirm_wake_email(link.id, "agent@example.com")
    assert Links.show_wake_email(link) == %{address: "agent@example.com", confirmed: true}
    assert {:ok, _link} = Links.confirm_wake_email(link.id, "agent@example.com")

    {:ok, link} = Links.delete_wake_email(link)
    assert Links.show_wake_email(link) == nil
    assert Repo.reload!(link).wake_email_confirmed_at == nil
    assert {:ok, _link} = Links.delete_wake_email(link)
  end

  test "keeps a confirmed address confirmed when it is set again", %{link: link} do
    {:ok, link} = Links.put_wake_email(link, %{"address" => "agent@example.com"})
    {:ok, link} = Links.confirm_wake_email(link.id, "agent@example.com")

    {:ok, link} = Links.put_wake_email(link, %{"address" => "agent@example.com"})
    assert Links.show_wake_email(link).confirmed
  end

  test "a changed address needs a new confirmation, and the old one no longer confirms", %{link: link} do
    {:ok, link} = Links.put_wake_email(link, %{"address" => "old@example.com"})
    {:ok, link} = Links.confirm_wake_email(link.id, "old@example.com")

    {:ok, link} = Links.put_wake_email(link, %{"address" => "new@example.com"})
    assert Links.show_wake_email(link) == %{address: "new@example.com", confirmed: false}
    assert Links.status(link) == :offline

    assert Links.confirm_wake_email(link.id, "old@example.com") == {:error, :invalid}
    assert Links.show_wake_email(Repo.reload!(link)).confirmed == false
  end

  test "does not confirm a cleared address, an unknown Link, or a Link of a deleted account", %{
    scope: scope,
    link: link
  } do
    {:ok, link} = Links.put_wake_email(link, %{"address" => "agent@example.com"})
    {:ok, _link} = Links.delete_wake_email(link)
    assert Links.confirm_wake_email(link.id, "agent@example.com") == {:error, :invalid}
    assert Links.confirm_wake_email(Ecto.UUID.generate(), "agent@example.com") == {:error, :invalid}

    {:ok, link} = Links.put_wake_email(Repo.reload!(link), %{"address" => "agent@example.com"})
    :ok = Accounts.delete_account(scope)
    assert Links.confirm_wake_email(link.id, "agent@example.com") == {:error, :invalid}
  end

  test "rejects an invalid address and keeps the old one", %{link: link} do
    {:ok, link} = Links.put_wake_email(link, %{"address" => "agent@example.com"})

    for params <- [
          %{},
          %{"address" => ""},
          %{"address" => "agent"},
          %{"address" => "a b@example.com"},
          %{"address" => "a@b@example.com"},
          %{"address" => "agent@example.com\r\nBcc: x@example.com"},
          %{"address" => 1},
          %{"address" => String.duplicate("a", 250) <> "@example.com"}
        ] do
      assert {:error, %Ecto.Changeset{}} = Links.put_wake_email(link, params)
    end

    assert Links.show_wake_email(Repo.reload!(link)).address == "agent@example.com"
  end

  test "a Link with a confirmed wake email is idle, unconfirmed or cleared it is offline", %{link: link} do
    :ok = Accounts.subscribe(link.account_id)
    link_id = link.id

    {:ok, link} = Links.put_wake_email(link, %{"address" => "agent@example.com"})
    assert Links.status(link) == :offline

    {:ok, link} = Links.confirm_wake_email(link.id, "agent@example.com")
    assert Links.status(link) == :idle
    assert_received {:link_status, %{link_id: ^link_id, status: :idle}}

    {:ok, link} = Links.delete_wake_email(link)
    assert Links.status(link) == :offline
    assert_received {:link_status, %{link_id: ^link_id, status: :offline}}
  end

  test "a connected Link with a confirmed wake email is online", %{link: link} do
    {:ok, link} = Links.put_wake_email(link, %{"address" => "agent@example.com"})
    {:ok, link} = Links.confirm_wake_email(link.id, "agent@example.com")
    :ok = Links.connect(link)

    assert Links.status(link) == :online
  end

  test "claims a Link with a confirmed wake email like one with a webhook, once in 30 seconds", %{
    scope: scope,
    link: link
  } do
    assistant = Repo.preload(link, :assistant).assistant
    {unconfirmed, _token} = another_paired_link_fixture(scope, assistant)
    {hooked, _token} = another_paired_link_fixture(scope, assistant)
    {:ok, link} = Links.put_wake_email(link, %{"address" => "agent@example.com"})
    {:ok, _link} = Links.confirm_wake_email(link.id, "agent@example.com")
    {:ok, _link} = Links.put_wake_email(unconfirmed, %{"address" => "other@example.com"})
    {:ok, _link} = Links.put_webhook(hooked, %{"url" => "https://a.test"})
    event = user_message_fixture(scope, assistant)

    claimed = Links.claim_wake_links(event)
    assert claimed |> Enum.map(& &1.id) |> Enum.sort() == Enum.sort([link.id, hooked.id])
    assert Enum.all?(claimed, &(&1.assistant.name == "Hermes"))
    assert Links.claim_wake_links(event) == []
  end

  test "does not claim a Link with only a wake email when the app opens", %{scope: scope, link: link} do
    {:ok, link} = Links.put_wake_email(link, %{"address" => "agent@example.com"})
    {:ok, _link} = Links.confirm_wake_email(link.id, "agent@example.com")

    assert Links.claim_account_wake_links(scope) == []
    assert Repo.get!(Link, link.id).webhook_pinged_at == nil
  end
end
