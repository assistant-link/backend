defmodule AssistantLinkWeb.JSONRPC do
  @moduledoc """
  JSON-RPC 2.0 messages, one per WebSocket text frame, as spoken on ALP's agent connection and the
  app's live connection. Batches are rejected.

  Errors outside the standard codes are server errors in `-32000..-32099`, with a stable snake_case
  reason in `data.reason` (`server_error/3`).
  """

  @type id :: String.t() | number() | nil
  @type params :: map() | list()
  @type error :: %{required(:code) => integer(), required(:message) => String.t(), optional(:data) => map()}
  @type message ::
          {:request, id(), String.t(), params()}
          | {:notification, String.t(), params()}
          | {:response, id(), {:ok, term()} | {:error, map()}}
  @type route :: (String.t(), params() -> {:ok, term()} | {:error, error()})

  @doc """
  Decodes and validates one frame. A request or notification without params gets `%{}`. Returns the
  error response to send back for a frame that is not a valid JSON-RPC 2.0 message.
  """
  @spec decode(binary()) :: {:ok, message()} | {:error, map()}
  def decode(frame) do
    case Jason.decode(frame) do
      {:ok, %{} = object} -> validate(object)
      {:ok, list} when is_list(list) -> {:error, error_response(nil, invalid_request("batches are not supported."))}
      {:ok, _scalar} -> {:error, error_response(nil, invalid_request("expected a JSON object."))}
      {:error, _decode_error} -> {:error, error_response(nil, %{code: -32_700, message: "Invalid JSON."})}
    end
  end

  defp validate(%{"jsonrpc" => "2.0"} = object) do
    cond do
      not valid_id?(object) -> invalid(object, "id must be a string, a number, or null.")
      is_map_key(object, "method") -> validate_call(object)
      true -> validate_response(object)
    end
  end

  defp validate(object), do: invalid(object, ~s(jsonrpc must be "2.0".))

  defp validate_call(%{"method" => method} = object) when is_binary(method) do
    case Map.get(object, "params", %{}) do
      params when not is_map(params) and not is_list(params) -> invalid(object, "params must be an object or an array.")
      params when is_map_key(object, "id") -> {:ok, {:request, object["id"], method, params}}
      params -> {:ok, {:notification, method, params}}
    end
  end

  defp validate_call(object), do: invalid(object, "method must be a string.")

  defp validate_response(%{"id" => id, "result" => result} = object) when not is_map_key(object, "error"),
    do: {:ok, {:response, id, {:ok, result}}}

  defp validate_response(%{"id" => id, "error" => %{"code" => code, "message" => message} = error} = object)
       when is_integer(code) and is_binary(message) and not is_map_key(object, "result"),
       do: {:ok, {:response, id, {:error, error}}}

  defp validate_response(object), do: invalid(object, "expected a request, a notification, or a response.")

  defp valid_id?(%{"id" => id}), do: is_binary(id) or is_number(id) or is_nil(id)
  defp valid_id?(_no_id), do: true

  defp invalid(object, message) do
    id = if valid_id?(object), do: Map.get(object, "id")
    {:error, error_response(id, invalid_request(message))}
  end

  @doc """
  Decodes one frame and answers it: calls `route` with a request's method and params and returns the
  response to send. Returns `nil` for notifications and responses, which get no answer.
  """
  @spec reply(binary(), route()) :: map() | nil
  def reply(frame, route), do: frame |> decode() |> reply_to(route)

  @doc "Answers a result of `decode/1` as `reply/2` does."
  @spec reply_to({:ok, message()} | {:error, map()}, route()) :: map() | nil
  def reply_to({:ok, {:request, id, method, params}}, route), do: answer(id, route.(method, params))
  def reply_to({:ok, _notification_or_response}, _route), do: nil
  def reply_to({:error, response}, _route), do: response

  defp answer(id, {:ok, result}), do: result_response(id, result)
  defp answer(id, {:error, error}), do: error_response(id, error)

  @doc "A route for a connection that implements no methods yet."
  @spec no_methods(String.t(), params()) :: {:error, error()}
  def no_methods(method, _params), do: {:error, method_not_found(method)}

  @spec request(id(), String.t(), params()) :: map()
  def request(id, method, params), do: %{jsonrpc: "2.0", id: id, method: method, params: params}

  @spec notification(String.t(), map()) :: map()
  def notification(method, params), do: %{jsonrpc: "2.0", method: method, params: params}

  @spec result_response(id(), term()) :: map()
  def result_response(id, result), do: %{jsonrpc: "2.0", id: id, result: result}

  @spec error_response(id(), error()) :: map()
  def error_response(id, error), do: %{jsonrpc: "2.0", id: id, error: error}

  @spec invalid_request(String.t()) :: error()
  def invalid_request(message), do: %{code: -32_600, message: "Invalid request: " <> message}

  @spec method_not_found(String.t()) :: error()
  def method_not_found(method), do: %{code: -32_601, message: "Method not found: " <> method}

  @spec invalid_params(String.t()) :: error()
  def invalid_params(message), do: %{code: -32_602, message: "Invalid params: " <> message}

  @spec server_error(integer(), String.t(), String.t()) :: error()
  def server_error(code, reason, message) when code in -32_099..-32_000,
    do: %{code: code, message: message, data: %{reason: reason}}

  @spec encode!(map()) :: iodata()
  def encode!(message), do: Jason.encode_to_iodata!(message)
end
