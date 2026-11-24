defmodule AssistantLinkWeb.ALP.HangupJSON do
  def show(%{event: event}), do: %{event_id: event.id, created_at: event.inserted_at}
end
