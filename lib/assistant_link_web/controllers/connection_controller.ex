defmodule AssistantLinkWeb.ConnectionController do
  use AssistantLinkWeb, :controller

  alias AssistantLinkWeb.Connection

  def agent(conn, _params), do: Connection.upgrade(conn, {:agent, conn.assigns.current_link})

  def app(conn, _params), do: Connection.upgrade(conn, {:app, conn.assigns.current_scope.account.id})
end
