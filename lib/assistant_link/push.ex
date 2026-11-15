defmodule AssistantLink.Push do
  @moduledoc """
  Sends an APNs alert to every device of a Link's account for each new agent message: the Assistant's
  name as the title, a preview of the text as the body, the default sound, and the Link id as the
  thread id. Next to `aps`, the payload has `link_id`, `assistant_id` and `event_id`. A message while
  the Assistant is on a call gets no push; the call speaks it.

  The requests to APNs run in the background and never fail the message. Without an APNs key it only logs. A token
  APNs reports as unregistered or bad is dropped.
  """
  alias AssistantLink.Accounts
  alias AssistantLink.Events
  alias AssistantLink.Events.Event
  alias AssistantLink.Links.Link
  alias AssistantLink.Push.ProviderToken

  require Logger

  @preview_length 150
  @hosts %{production: "https://api.push.apple.com", sandbox: "https://api.sandbox.push.apple.com"}

  @doc "Pushes the agent message `event` of the Link, whose Assistant is preloaded."
  @spec notify(Link.t(), Event.t()) :: :ok
  def notify(%Link{} = link, %Event{type: :text_message, sender: :assistant} = event) do
    config = Application.get_env(:assistant_link, __MODULE__, [])

    if config[:key_p8] do
      push(config, link, event)
    else
      Logger.info("APNs is not configured; no push for event #{event.id}")
    end

    :ok
  end

  defp push(config, link, event) do
    tokens = Accounts.list_push_tokens(link.account_id)

    if tokens != [] and not Events.on_call?(link.assistant_id) do
      payload = Jason.encode!(payload(link, event))
      Task.Supervisor.start_child(__MODULE__.Supervisor, fn -> send_pushes(config, tokens, event.id, payload) end)
    end
  end

  defp send_pushes(config, tokens, event_id, payload), do: Enum.each(tokens, &send_push(config, &1, event_id, payload))

  defp payload(link, event) do
    %{
      aps: %{
        alert: %{title: link.assistant.name, body: preview(event.text_message.text)},
        sound: "default",
        "thread-id": link.id
      },
      link_id: link.id,
      assistant_id: link.assistant_id,
      event_id: event.id
    }
  end

  # Cuts at a word boundary unless the last word is long, as a URL can be.
  defp preview(text) do
    if String.length(text) <= @preview_length do
      text
    else
      text
      |> String.slice(0, @preview_length - 1)
      |> String.replace(~r/\s+\S{0,20}\z/u, "")
      |> Kernel.<>("…")
    end
  end

  defp send_push(config, token, event_id, payload) do
    headers = [
      {"authorization", "bearer " <> ProviderToken.get(config)},
      {"apns-topic", Keyword.fetch!(config, :topic)},
      {"apns-push-type", "alert"},
      {"apns-priority", "10"},
      {"apns-id", event_id}
    ]

    url = Map.fetch!(@hosts, Keyword.fetch!(config, :env)) <> "/3/device/" <> token

    case Keyword.fetch!(config, :client).post(url, headers, payload) do
      {:ok, 200, _body} -> :ok
      {:ok, status, body} -> rejected(token, status, reason(body))
      {:error, error} -> Logger.warning("APNs request for event #{event_id} failed: #{inspect(error)}")
    end
  end

  defp rejected(token, 410, _reason), do: Accounts.drop_push_token(token)
  defp rejected(token, 400, "BadDeviceToken"), do: Accounts.drop_push_token(token)
  defp rejected(_token, status, reason), do: Logger.warning("APNs answered #{status} #{reason}")

  defp reason(body) do
    case Jason.decode(body) do
      {:ok, %{"reason" => reason}} -> reason
      _other -> ""
    end
  end
end
