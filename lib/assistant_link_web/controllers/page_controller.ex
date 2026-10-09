defmodule AssistantLinkWeb.PageController do
  use AssistantLinkWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
