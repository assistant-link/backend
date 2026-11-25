defmodule AssistantLinkWeb.API.LinkJSON do
  alias AssistantLink.Links

  def show(%{link: link}), do: %{link: link(link)}

  def link(link) do
    %{
      id: link.id,
      label: link.label,
      status: Links.status(link),
      last_active_at: link.last_active_at,
      activity: Links.activity(link),
      webhook_installed: Links.webhook_installed?(link),
      wake_email: Links.show_wake_email(link),
      wake_route: Links.wake_route(link)
    }
  end
end
