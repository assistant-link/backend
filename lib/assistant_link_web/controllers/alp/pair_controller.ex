defmodule AssistantLinkWeb.ALP.PairController do
  use AssistantLinkWeb, :controller

  alias AssistantLink.Links
  alias AssistantLinkWeb.APIError

  action_fallback AssistantLinkWeb.API.FallbackController

  def create(conn, %{"code" => code}) when is_binary(code) do
    with {:ok, %{link: link, token: token}} <- Links.pair(code) do
      json(conn, %{link_id: link.id, assistant_name: link.assistant.name, token: token})
    end
  end

  def create(conn, _params) do
    APIError.send_error(conn, 422, "invalid_params", "code must be a string")
  end
end
