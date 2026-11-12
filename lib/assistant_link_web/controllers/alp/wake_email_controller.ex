defmodule AssistantLinkWeb.ALP.WakeEmailController do
  use AssistantLinkWeb, :controller

  alias AssistantLink.Links
  alias AssistantLinkWeb.WakeEmail

  action_fallback AssistantLinkWeb.API.FallbackController

  def show(conn, _params), do: render(conn, :show, link: conn.assigns.current_link)

  def update(conn, params) do
    with {:ok, link} <- Links.put_wake_email(conn.assigns.current_link, params) do
      if link.wake_email_confirmed_at == nil, do: WakeEmail.send_confirmation(link)
      render(conn, :show, link: link)
    end
  end

  def delete(conn, _params) do
    {:ok, _link} = Links.delete_wake_email(conn.assigns.current_link)
    send_resp(conn, 204, "")
  end
end
