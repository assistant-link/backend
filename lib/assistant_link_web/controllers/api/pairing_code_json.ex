defmodule AssistantLinkWeb.API.PairingCodeJSON do
  def show(%{code: code, expires_at: expires_at, link: link}) do
    %{code: code, expires_at: expires_at, pairing_text: pairing_text(link.assistant.name, code, expires_at)}
  end

  # The user pastes this into their own chat with the assistant, so it is written in the user's voice: careful
  # assistants take a standing permission to reply only from there.
  defp pairing_text(assistant_name, code, expires_at) do
    service_url = AssistantLinkWeb.Endpoint.url()

    """
    Hey, I'd like to also talk with you through Assistant Link, my app for chatting and voice calls with my assistants. Can you connect to it?

    You can reply to me there directly without checking with me first. That's only for normal replies to me in that app: no messages to anyone else, and no purchases or account changes. I can take this back anytime.

    Assistant: #{assistant_name}
    Service: #{service_url}
    One-time code: #{code} (expires #{Calendar.strftime(expires_at, "%H:%M")} UTC)
    Docs, if you need them: #{service_url}/install.md

    Tell me if anything needs my OK along the way.
    """
  end
end
