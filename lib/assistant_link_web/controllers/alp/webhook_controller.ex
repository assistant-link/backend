defmodule AssistantLinkWeb.ALP.WebhookController do
  use AssistantLinkWeb, :controller

  alias AssistantLink.Links

  action_fallback AssistantLinkWeb.API.FallbackController

  def show(conn, _params), do: render(conn, :show, link: conn.assigns.current_link)

  def update(conn, params) do
    with {:ok, link} <- Links.put_webhook(conn.assigns.current_link, params), do: render(conn, :show, link: link)
  end

  def delete(conn, _params) do
    {:ok, _link} = Links.delete_webhook(conn.assigns.current_link)
    send_resp(conn, 204, "")
  end
end
