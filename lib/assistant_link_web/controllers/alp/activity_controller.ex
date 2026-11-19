defmodule AssistantLinkWeb.ALP.ActivityController do
  use AssistantLinkWeb, :controller

  alias AssistantLink.Links

  action_fallback AssistantLinkWeb.API.FallbackController

  def update(conn, %{"text" => text}) when is_binary(text) do
    with {:ok, activity} <- Links.put_activity(conn.assigns.current_link, text),
         do: render(conn, :show, activity: activity)
  end

  def update(_conn, _params), do: {:error, :invalid_params}

  def delete(conn, _params) do
    :ok = Links.clear_activity(conn.assigns.current_link)
    send_resp(conn, 204, "")
  end
end
