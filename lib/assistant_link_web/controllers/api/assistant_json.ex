defmodule AssistantLinkWeb.API.AssistantJSON do
  alias AssistantLinkWeb.API.LinkJSON

  def index(%{assistants: assistants}), do: %{assistants: Enum.map(assistants, &assistant/1)}

  def show(%{assistant: assistant}), do: %{assistant: assistant(assistant)}

  def assistant(assistant) do
    links = Enum.map(assistant.links, &LinkJSON.link/1)

    %{
      id: assistant.id,
      name: assistant.name,
      avatar: assistant.avatar,
      status: if(Enum.any?(links, &(&1.status == :online)), do: :online, else: :offline),
      links: links
    }
  end
end
