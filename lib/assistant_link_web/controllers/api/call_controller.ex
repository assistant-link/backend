defmodule AssistantLinkWeb.API.CallController do
  use AssistantLinkWeb, :controller

  alias AssistantLink.Calls
  alias AssistantLinkWeb.Webhook

  action_fallback AssistantLinkWeb.API.FallbackController

  def create(conn, %{"assistant_id" => assistant_id} = params) do
    with {:ok, call, call_started} <- Calls.start_call(conn.assigns.current_scope, assistant_id, params) do
      Webhook.notify(call_started)

      conn
      |> put_status(:created)
      |> render(:show, call: call)
    end
  end

  def show(conn, %{"assistant_id" => assistant_id, "id" => id}) do
    with {:ok, call} <- Calls.get_call(conn.assigns.current_scope, assistant_id, id) do
      render(conn, :show, call: call)
    end
  end

  def hang_up(conn, %{"assistant_id" => assistant_id, "id" => id}) do
    with {:ok, call} <- Calls.end_call(conn.assigns.current_scope, assistant_id, id) do
      render(conn, :show, call: call)
    end
  end
end
