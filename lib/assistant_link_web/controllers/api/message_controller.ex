defmodule AssistantLinkWeb.API.MessageController do
  use AssistantLinkWeb, :controller

  alias AssistantLink.Events

  action_fallback AssistantLinkWeb.API.FallbackController

  def create(conn, %{"assistant_id" => assistant_id} = params) do
    with {:ok, event, outcome} <- Events.create_text_message(conn.assigns.current_scope, assistant_id, params) do
      conn
      |> put_status(if outcome == :created, do: :created, else: :ok)
      |> render(:show, event: event)
    end
  end
end
