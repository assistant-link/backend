defmodule AssistantLink.Push.FinchClient do
  @moduledoc "The APNs client: Finch's HTTP/2 pool `AssistantLink.Push.Finch`."
  @behaviour AssistantLink.Push.Client

  @impl AssistantLink.Push.Client
  def post(url, headers, body) do
    case :post |> Finch.build(url, headers, body) |> Finch.request(AssistantLink.Push.Finch, receive_timeout: 10_000) do
      {:ok, %Finch.Response{status: status, body: body}} -> {:ok, status, body}
      {:error, exception} -> {:error, exception}
    end
  end
end
