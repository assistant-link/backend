defmodule AssistantLinkWeb.ALP.MessageController do
  use AssistantLinkWeb, :controller

  alias AssistantLink.Events
  alias AssistantLink.Links
  alias AssistantLink.Push

  action_fallback AssistantLinkWeb.API.FallbackController

  def create(conn, params) do
    link = conn.assigns.current_link

    with {:ok, event, outcome} <- Events.create_assistant_message(link, params) do
      if outcome == :created do
        Links.clear_activity(link)
        Push.notify(link, event)
      end

      conn
      |> put_status(if outcome == :created, do: :created, else: :ok)
      |> render(:show, event: event)
    end
  end
end
