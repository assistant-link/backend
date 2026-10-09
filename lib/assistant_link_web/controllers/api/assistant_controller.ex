defmodule AssistantLinkWeb.API.AssistantController do
  use AssistantLinkWeb, :controller

  alias AssistantLink.Assistants

  action_fallback AssistantLinkWeb.API.FallbackController

  def index(conn, _params) do
    render(conn, :index, assistants: Assistants.list_assistants(conn.assigns.current_scope))
  end

  def create(conn, params) do
    with {:ok, assistant} <- Assistants.create_assistant(conn.assigns.current_scope, params) do
      conn
      |> put_status(:created)
      |> render(:show, assistant: assistant)
    end
  end
end
