defmodule AssistantLinkWeb.API.CallController do
  use AssistantLinkWeb, :controller

  alias AssistantLink.Calls
  alias AssistantLink.Voice
  alias AssistantLinkWeb.Webhook

  action_fallback AssistantLinkWeb.API.FallbackController

  def create(conn, %{"assistant_id" => assistant_id} = params) do
    case Calls.start_call(conn.assigns.current_scope, assistant_id, params) do
      {:ok, call, :existing} ->
        render(conn, :show, call: call)

      {:ok, call, call_started} ->
        Webhook.notify(call_started)

        conn
        |> put_status(:created)
        |> render(:show, call: call)

      error ->
        error
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

  def webrtc(conn, %{"assistant_id" => assistant_id, "id" => id} = params) do
    with {:ok, answer} <- Voice.connect(conn.assigns.current_scope, assistant_id, id, params["offer"]) do
      render(conn, :webrtc, answer: answer)
    end
  end
end
