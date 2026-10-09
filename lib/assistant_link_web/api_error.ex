defmodule AssistantLinkWeb.APIError do
  @moduledoc """
  The JSON error body shared by the client API and ALP: `{"error": {"code": ..., "message": ...}}`, where
  `code` is a stable snake_case identifier clients can match on.
  """
  import Plug.Conn

  @doc "Builds the error body."
  @spec body(String.t(), String.t()) :: map()
  def body(code, message), do: %{error: %{code: code, message: message}}

  @doc "Sends an error response with the given status and halts the plug pipeline."
  @spec send_error(Plug.Conn.t(), Plug.Conn.status(), String.t(), String.t()) :: Plug.Conn.t()
  def send_error(conn, status, code, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode_to_iodata!(body(code, message)))
    |> halt()
  end
end
