defmodule AssistantLinkWeb.Webhook do
  @moduledoc """
  Wakes agents: posts a user's new text message, as `event.deliver` sends it, to the webhook of each
  paired Link of the Assistant. It is a best-effort signal; delivery over the agent connection stays
  the reliable path. Transport errors, 408, 429 and 5xx are retried up to 3 times.
  """
  alias AssistantLink.Events.Event
  alias AssistantLink.Links
  alias AssistantLinkWeb.API.EventJSON

  require Logger

  @spec notify(Event.t()) :: :ok
  def notify(%Event{} = event) do
    body = EventJSON.delivery(event)

    for link <- Links.list_webhook_links(event) do
      Task.Supervisor.start_child(__MODULE__.Supervisor, fn -> post(link, body) end)
    end

    :ok
  end

  defp post(link, body) do
    headers = if link.webhook_authorization, do: [authorization: link.webhook_authorization], else: []

    options =
      [
        url: link.webhook_url,
        json: body,
        headers: headers,
        receive_timeout: 10_000,
        retry: :transient,
        max_retries: 3
      ] ++ Keyword.get(Application.get_env(:assistant_link, __MODULE__, []), :req_options, [])

    case request(options) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Req.Response{status: status}} -> Logger.warning("Webhook of Link #{link.id} answered #{status}")
      {:error, exception} -> Logger.warning("Webhook of Link #{link.id} failed: #{Exception.message(exception)}")
    end
  end

  # A host Req cannot connect to (a space, a non-ASCII character, a bad port) raises or exits.
  defp request(options) do
    Req.post(options)
  rescue
    exception -> {:error, exception}
  catch
    :exit, _reason -> {:error, RuntimeError.exception("the request exited")}
  end
end
