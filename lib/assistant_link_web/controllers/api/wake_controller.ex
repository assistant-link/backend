defmodule AssistantLinkWeb.API.WakeController do
  use AssistantLinkWeb, :controller

  alias AssistantLinkWeb.Webhook

  def create(conn, _params) do
    :ok = Webhook.wake_account(conn.assigns.current_scope)
    send_resp(conn, :no_content, "")
  end
end
