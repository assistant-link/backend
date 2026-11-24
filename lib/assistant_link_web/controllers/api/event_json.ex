defmodule AssistantLinkWeb.API.EventJSON do
  def index(%{events: events, has_more: has_more}), do: %{events: Enum.map(events, &event/1), has_more: has_more}

  def show(%{event: event}), do: %{event: event(event)}

  @doc "The event as the params of `event.deliver`."
  def delivery(event) do
    base = %{id: event.id, type: event.type, created_at: event.inserted_at, deleted: deleted?(event)}
    base |> Map.merge(reply_to(event)) |> Map.merge(payload(event))
  end

  def event(event) do
    own = %{
      assistant_id: event.assistant_id,
      sender: event.sender,
      link_id: event.link_id,
      idempotency_key: event.idempotency_key
    }

    event |> delivery() |> Map.merge(own) |> Map.merge(delivery_status(event))
  end

  defp deleted?(event), do: event.type == :text_message and is_nil(event.text_message)

  defp delivery_status(%{sender: :user, delivered_at: delivered_at}),
    do: %{delivery_status: if(delivered_at, do: :delivered, else: :sent)}

  defp delivery_status(_event), do: %{}

  defp reply_to(%{reply_to: nil}), do: %{}
  defp reply_to(%{reply_to: id}), do: %{reply_to: id}

  defp payload(%{text_message: %{text: text, via: nil}}), do: %{text_message: %{text: text}}
  defp payload(%{text_message: %{text: text, via: via}}), do: %{text_message: %{text: text, via: via}}
  defp payload(_event), do: %{}
end
