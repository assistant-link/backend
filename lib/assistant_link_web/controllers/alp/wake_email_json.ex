defmodule AssistantLinkWeb.ALP.WakeEmailJSON do
  alias AssistantLink.Links

  def show(%{link: link}), do: %{wake_email: Links.show_wake_email(link)}
end
