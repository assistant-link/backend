defmodule AssistantLinkWeb.API.PairingCodeJSON do
  def show(%{code: code, expires_at: expires_at, link: link}) do
    %{code: code, expires_at: expires_at, pairing_text: pairing_text(link.assistant.name, code, expires_at)}
  end

  defp pairing_text(assistant_name, code, expires_at) do
    service_url = AssistantLinkWeb.Endpoint.url()

    """
    Connect to my assistant "#{assistant_name}" on Assistant Link.
    Follow the instructions at #{service_url}/install.md
    Service: #{service_url}
    Pairing code: #{code} (expires #{Calendar.strftime(expires_at, "%H:%M")} UTC)
    """
  end
end
