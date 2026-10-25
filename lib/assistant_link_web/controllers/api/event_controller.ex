defmodule AssistantLinkWeb.API.EventController do
  use AssistantLinkWeb, :controller

  alias AssistantLink.Events

  action_fallback AssistantLinkWeb.API.FallbackController

  def index(conn, %{"assistant_id" => assistant_id} = params) do
    with {:ok, page} <- Events.list_events(conn.assigns.current_scope, assistant_id, params) do
      render(conn, :index, page)
    end
  end
end
