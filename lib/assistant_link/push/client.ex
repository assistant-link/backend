defmodule AssistantLink.Push.Client do
  @moduledoc "Posts one request to APNs over HTTP/2."

  @callback post(url :: String.t(), headers :: [{String.t(), String.t()}], body :: iodata()) ::
              {:ok, status :: pos_integer(), body :: binary()} | {:error, term()}
end
