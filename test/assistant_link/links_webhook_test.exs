defmodule AssistantLink.LinksWebhookTest do
  use AssistantLink.DataCase, async: true

  import AssistantLink.AccountsFixtures
  import AssistantLink.LinksFixtures

  alias AssistantLink.Accounts
  alias AssistantLink.Links

  setup do
    {link, _token} = paired_link_fixture(user_scope_fixture())
    %{link: link}
  end

  test "sets, shows, replaces and clears the webhook", %{link: link} do
    assert Links.show_webhook(link) == nil

    {:ok, link} = Links.put_webhook(link, %{"url" => "https://a.test/hook", "authorization" => "Bearer secret"})
    assert Links.show_webhook(link) == %{url: "https://a.test/hook", authorization: "Bearer ***"}
    assert Repo.reload!(link).webhook_authorization == "Bearer secret"

    {:ok, link} = Links.put_webhook(link, %{"url" => "http://b.test/hook"})
    assert Links.show_webhook(link) == %{url: "http://b.test/hook", authorization: nil}

    {:ok, link} = Links.delete_webhook(link)
    assert Links.show_webhook(link) == nil
    assert {:ok, _link} = Links.delete_webhook(link)
  end

  test "tells the account's subscribers the Link is idle when the webhook is set, offline when cleared", %{
    link: link
  } do
    :ok = Accounts.subscribe(link.account_id)
    link_id = link.id

    {:ok, link} = Links.put_webhook(link, %{"url" => "https://a.test/hook"})
    assert Links.status(link) == :idle
    assert_received {:link_status, %{link_id: ^link_id, status: :idle, last_active_at: nil}}

    {:ok, link} = Links.delete_webhook(link)
    assert Links.status(link) == :offline
    assert_received {:link_status, %{link_id: ^link_id, status: :offline, last_active_at: nil}}
  end

  test "keeps a connected Link online and tells no one when its webhook changes", %{link: link} do
    :ok = Accounts.subscribe(link.account_id)
    :ok = Links.connect(link)
    assert_receive {:link_status, %{status: :online}}

    {:ok, link} = Links.put_webhook(link, %{"url" => "https://a.test/hook"})
    assert Links.status(link) == :online
    {:ok, _link} = Links.delete_webhook(link)

    refute_received {:link_status, _change}
  end

  test "tells no one when the webhook is rejected", %{link: link} do
    :ok = Accounts.subscribe(link.account_id)
    assert {:error, _changeset} = Links.put_webhook(link, %{"url" => "ftp://a.test"})
    refute_received {:link_status, _change}
  end

  test "masks an authorization without a space completely", %{link: link} do
    {:ok, link} = Links.put_webhook(link, %{"url" => "https://a.test", "authorization" => "secret"})
    assert Links.show_webhook(link).authorization == "***"
  end

  test "rejects an invalid webhook and keeps the old one", %{link: link} do
    {:ok, link} = Links.put_webhook(link, %{"url" => "https://a.test"})

    for params <- [
          %{},
          %{"url" => "ftp://a.test"},
          %{"url" => "/relative"},
          %{"url" => "https://"},
          %{"url" => 1},
          %{"url" => "https://a.test/" <> String.duplicate("a", 2048)},
          %{"url" => "https://a.test", "authorization" => "a\r\nb"},
          %{"url" => "https://a.test", "authorization" => String.duplicate("a", 4097)}
        ] do
      assert {:error, %Ecto.Changeset{}} = Links.put_webhook(link, params)
    end

    assert Links.show_webhook(Repo.reload!(link)).url == "https://a.test"
  end

  test "claims the offline paired Links with a webhook, none after the account is deleted" do
    scope = user_scope_fixture()
    {link, _token} = paired_link_fixture(scope)
    assistant = Repo.preload(link, :assistant).assistant
    {_plain, _token} = another_paired_link_fixture(scope, assistant)
    {:ok, unpaired} = Links.create_link(scope, assistant.id, %{})
    {:ok, link} = Links.put_webhook(link, %{"url" => "https://a.test"})
    {:ok, _unpaired} = Links.put_webhook(unpaired, %{"url" => "https://b.test"})
    event = user_message_fixture(scope, assistant)

    assert Enum.map(Links.claim_wake_links(event), & &1.id) == [link.id]

    Repo.update_all(AssistantLink.Links.Link, set: [webhook_pinged_at: nil])
    :ok = Accounts.delete_account(scope)
    assert Links.claim_wake_links(event) == []
  end
end
