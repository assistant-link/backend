defmodule AssistantLinkWeb.API.MessageJSON do
  alias AssistantLinkWeb.API.EventJSON

  def show(%{event: event}), do: %{message: EventJSON.event(event)}
end
