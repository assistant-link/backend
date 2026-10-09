defmodule AssistantLinkWeb.API.PairingCodeController do
  use AssistantLinkWeb, :controller

  alias AssistantLink.Links

  action_fallback AssistantLinkWeb.API.FallbackController

  def create(conn, %{"link_id" => link_id}) do
    with {:ok, pairing} <- Links.issue_pairing_code(conn.assigns.current_scope, link_id) do
      conn
      |> put_status(:created)
      |> render(:show, pairing)
    end
  end
end
