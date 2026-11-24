defmodule AssistantLinkWeb.ALP.HangupController do
  use AssistantLinkWeb, :controller

  alias AssistantLink.Events

  action_fallback AssistantLinkWeb.API.FallbackController

  def create(conn, params) do
    with {:ok, event, outcome} <- Events.hang_up(conn.assigns.current_link, params) do
      conn
      |> put_status(if outcome == :created, do: :created, else: :ok)
      |> render(:show, event: event)
    end
  end
end
