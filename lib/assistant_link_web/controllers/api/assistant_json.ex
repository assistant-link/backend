defmodule AssistantLinkWeb.API.AssistantJSON do
  alias AssistantLinkWeb.API.EventJSON
  alias AssistantLinkWeb.API.LinkJSON

  def index(%{assistants: assistants}), do: %{assistants: Enum.map(assistants, &assistant/1)}

  def show(%{assistant: assistant}), do: %{assistant: assistant(assistant)}

  def assistant(assistant) do
    links = Enum.map(assistant.links, &LinkJSON.link/1)

    %{
      id: assistant.id,
      name: assistant.name,
      avatar: assistant.avatar,
      status: status(links),
      links: links,
      latest_event: assistant.latest_event && EventJSON.event(assistant.latest_event)
    }
  end

  defp status(links) do
    cond do
      Enum.any?(links, &(&1.status == :online)) -> :online
      Enum.any?(links, &(&1.status == :idle)) -> :idle
      true -> :offline
    end
  end
end
