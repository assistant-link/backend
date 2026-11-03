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

  test "lists the paired Links with a webhook, none after the account is deleted" do
    scope = user_scope_fixture()
    {link, _token} = paired_link_fixture(scope)
    assistant = Repo.preload(link, :assistant).assistant
    {plain, _token} = another_paired_link_fixture(scope, assistant)
    {:ok, unpaired} = Links.create_link(scope, assistant.id, %{})
    {:ok, link} = Links.put_webhook(link, %{"url" => "https://a.test"})
    {:ok, _unpaired} = Links.put_webhook(unpaired, %{"url" => "https://b.test"})
    event = user_message_fixture(scope, assistant)

    assert Enum.map(Links.list_webhook_links(event), & &1.id) == [link.id]
    refute plain.id in Enum.map(Links.list_webhook_links(event), & &1.id)

    :ok = Accounts.delete_account(scope)
    assert Links.list_webhook_links(event) == []
  end
end
