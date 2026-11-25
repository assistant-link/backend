defmodule AssistantLink.LinksWakeRouteTest do
  use ExUnit.Case, async: true

  alias AssistantLink.Links
  alias AssistantLink.Links.Link

  @confirmed_at ~U[2026-11-25 12:00:00.000000Z]

  test "a webhook alone is the route" do
    link = %Link{webhook_url: "https://a.test/hook"}

    assert Links.webhook_installed?(link)
    assert Links.wake_route(link) == :webhook
  end

  test "a confirmed wake email alone is the route" do
    link = %Link{wake_email: "a@example.com", wake_email_confirmed_at: @confirmed_at}

    refute Links.webhook_installed?(link)
    assert Links.wake_route(link) == :email
  end

  test "a webhook wins over a confirmed wake email" do
    link = %Link{
      webhook_url: "https://a.test/hook",
      wake_email: "a@example.com",
      wake_email_confirmed_at: @confirmed_at
    }

    assert Links.webhook_installed?(link)
    assert Links.wake_route(link) == :webhook
  end

  test "a pending wake email is no route" do
    link = %Link{wake_email: "a@example.com"}

    refute Links.webhook_installed?(link)
    assert Links.wake_route(link) == nil
  end

  test "neither is no route" do
    refute Links.webhook_installed?(%Link{})
    assert Links.wake_route(%Link{}) == nil
  end
end
