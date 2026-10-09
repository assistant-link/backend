defmodule AssistantLinkWeb.ErrorJSON do
  @moduledoc """
  Renders errors the endpoint raises for JSON requests (for example 404 and 500) in the API error format
  of `AssistantLinkWeb.APIError`, with the status name as the code: `not_found`, `internal_server_error`.

  See config/config.exs.
  """
  alias AssistantLinkWeb.APIError

  def render(template, _assigns) do
    message = Phoenix.Controller.status_message_from_template(template)
    code = message |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_")

    APIError.body(code, message)
  end
end
