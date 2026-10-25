defmodule AssistantLinkWeb.ALP.MessageJSON do
  def show(%{event: event}), do: %{message_id: event.id, created_at: event.inserted_at}
end
