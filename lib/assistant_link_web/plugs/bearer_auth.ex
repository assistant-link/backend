defmodule AssistantLinkWeb.Plugs.BearerAuth do
  @moduledoc """
  Authenticates a request by its `Authorization: Bearer <token>` header.

      plug BearerAuth, :account   # client API: a device's account credential; assigns :current_scope
      plug BearerAuth, :link      # ALP: a Link token; assigns :current_link (with its Assistant)

  A missing, malformed, or unknown token gets `401` with error code `unauthorized`.
  """
  @behaviour Plug

  import Plug.Conn

  alias AssistantLink.Accounts
  alias AssistantLink.Links
  alias AssistantLinkWeb.APIError

  @impl Plug
  def init(kind) when kind in [:account, :link], do: kind

  @impl Plug
  def call(conn, kind) do
    with {:ok, token} <- bearer_token(conn),
         %{} = subject <- lookup(kind, token) do
      assign(conn, assign_key(kind), subject)
    else
      _missing_or_unknown -> APIError.send_error(conn, 401, "unauthorized", "Missing or invalid bearer token.")
    end
  end

  defp bearer_token(conn) do
    with [header] <- get_req_header(conn, "authorization"),
         [scheme, token] <- String.split(header, " ", parts: 2),
         "bearer" <- String.downcase(scheme),
         token when token != "" <- String.trim(token) do
      {:ok, token}
    else
      _other -> :error
    end
  end

  defp lookup(:account, token), do: Accounts.get_scope_by_device_token(token)
  defp lookup(:link, token), do: Links.get_link_by_token(token)

  defp assign_key(:account), do: :current_scope
  defp assign_key(:link), do: :current_link
end
