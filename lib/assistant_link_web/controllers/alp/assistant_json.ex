defmodule AssistantLinkWeb.ALP.AssistantJSON do
  def show(%{assistant: assistant}), do: %{name: assistant.name, platform: assistant.platform}
end
