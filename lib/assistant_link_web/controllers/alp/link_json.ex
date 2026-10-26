defmodule AssistantLinkWeb.ALP.LinkJSON do
  def show(%{link: link, unread_count: unread_count}),
    do: %{link_id: link.id, assistant_name: link.assistant.name, unread_count: unread_count}
end
