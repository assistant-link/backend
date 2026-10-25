defmodule AssistantLinkWeb.API.AccountController do
  use AssistantLinkWeb, :controller

  alias AssistantLink.Accounts

  action_fallback AssistantLinkWeb.API.FallbackController

  def create(conn, _params) do
    {:ok, registration} = Accounts.register_device()

    conn
    |> put_status(:created)
    |> render(:show, registration)
  end

  def delete(conn, _params) do
    with :ok <- Accounts.delete_account(conn.assigns.current_scope) do
      send_resp(conn, :no_content, "")
    end
  end
end
