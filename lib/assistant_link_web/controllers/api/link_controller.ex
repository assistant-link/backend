defmodule AssistantLinkWeb.API.LinkController do
  use AssistantLinkWeb, :controller

  alias AssistantLink.Links

  action_fallback AssistantLinkWeb.API.FallbackController

  def create(conn, %{"assistant_id" => assistant_id} = params) do
    with {:ok, link} <- Links.create_link(conn.assigns.current_scope, assistant_id, params) do
      conn
      |> put_status(:created)
      |> render(:show, link: link)
    end
  end
end
