defmodule AssistantLinkWeb.API.PushTokenController do
  use AssistantLinkWeb, :controller

  alias AssistantLink.Accounts

  action_fallback AssistantLinkWeb.API.FallbackController

  def update(conn, params) do
    with :ok <- Accounts.put_push_token(conn.assigns.current_scope, params["token"]) do
      send_resp(conn, :no_content, "")
    end
  end

  def delete(conn, _params) do
    :ok = Accounts.delete_push_token(conn.assigns.current_scope)
    send_resp(conn, :no_content, "")
  end
end
