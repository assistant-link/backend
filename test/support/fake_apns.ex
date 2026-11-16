defmodule AssistantLink.Push.FakeAPNs do
  @moduledoc """
  An APNs client for tests. It sends `{:apns_request, pid, url, headers, body}` to the processes that
  started the push, `pid` being the sending process, and answers by the device token's prefix: `410`
  as an unregistered token, `400` as a bad one, `500` as a server error, anything else with 200.
  """
  @behaviour AssistantLink.Push.Client

  @impl AssistantLink.Push.Client
  def post(url, headers, body) do
    for pid <- Process.get(:"$callers", []), do: send(pid, {:apns_request, self(), url, headers, body})

    url |> String.split("/") |> List.last() |> answer()
  end

  defp answer("410" <> _rest), do: {:ok, 410, ~s({"reason":"Unregistered"})}
  defp answer("400" <> _rest), do: {:ok, 400, ~s({"reason":"BadDeviceToken"})}
  defp answer("500" <> _rest), do: {:ok, 500, ~s({"reason":"InternalServerError"})}
  defp answer(_token), do: {:ok, 200, ""}
end
