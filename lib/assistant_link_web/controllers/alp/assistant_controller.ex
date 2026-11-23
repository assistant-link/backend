defmodule AssistantLinkWeb.ALP.AssistantController do
  use AssistantLinkWeb, :controller

  alias AssistantLink.Assistants

  action_fallback AssistantLinkWeb.API.FallbackController

  def show(conn, _params), do: render(conn, :show, assistant: conn.assigns.current_link.assistant)

  def update(conn, params) do
    with {:ok, assistant} <- Assistants.update_assistant(conn.assigns.current_link.assistant, params),
         do: render(conn, :show, assistant: assistant)
  end
end
