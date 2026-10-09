defmodule AssistantLinkWeb.HealthController do
  use AssistantLinkWeb, :controller

  def show(conn, _params) do
    json(conn, %{status: "ok"})
  end
end
