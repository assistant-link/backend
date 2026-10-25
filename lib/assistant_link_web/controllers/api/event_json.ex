defmodule AssistantLinkWeb.API.EventJSON do
  def index(%{events: events, has_more: has_more}), do: %{events: Enum.map(events, &event/1), has_more: has_more}

  def show(%{event: event}), do: %{event: event(event)}

  @doc "An event with its payload under its type, and no payload key once deleted."
  def event(event) do
    base = %{
      id: event.id,
      assistant_id: event.assistant_id,
      type: event.type,
      sender: event.sender,
      link_id: event.link_id,
      created_at: event.inserted_at,
      deleted: deleted?(event),
      idempotency_key: event.idempotency_key
    }

    base |> Map.merge(delivery_status(event)) |> Map.merge(payload(event))
  end

  defp deleted?(event), do: event.type == :text_message and is_nil(event.text_message)

  defp delivery_status(%{type: :text_message, sender: :user, delivered_at: delivered_at}),
    do: %{delivery_status: if(delivered_at, do: :delivered, else: :sent)}

  defp delivery_status(_event), do: %{}

  defp payload(%{type: :text_message, text_message: %{text: text}}), do: %{text_message: %{text: text}}
  defp payload(_event), do: %{}
end
