defmodule AssistantLinkWeb.API.LinkJSON do
  alias AssistantLink.Links

  def show(%{link: link}), do: %{link: link(link)}

  def link(link) do
    %{
      id: link.id,
      label: link.label,
      status: Links.status(link),
      last_active_at: link.last_active_at
    }
  end
end
