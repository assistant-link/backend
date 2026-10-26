defmodule AssistantLinkWeb.ALP.LinkController do
  use AssistantLinkWeb, :controller

  alias AssistantLink.Events

  def show(conn, _params) do
    link = conn.assigns.current_link
    render(conn, :show, link: link, unread_count: Events.count_deliverable(link.id))
  end
end
