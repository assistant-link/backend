defmodule AssistantLinkWeb.ALP.WebhookJSON do
  alias AssistantLink.Links

  def show(%{link: link}), do: %{webhook: Links.show_webhook(link)}
end
