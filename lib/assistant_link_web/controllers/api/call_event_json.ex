defmodule AssistantLinkWeb.API.CallEventJSON do
  alias AssistantLinkWeb.API.EventJSON

  defdelegate show(assigns), to: EventJSON
end
