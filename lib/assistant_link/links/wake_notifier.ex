defmodule AssistantLink.Links.WakeNotifier do
  @moduledoc """
  The emails sent to a Link's wake email: the confirmation of a new address, and the wake-up itself. Both
  come from a no-reply address, as the agent answers the user with `al send`.
  """
  import Swoosh.Email

  alias AssistantLink.Events.Event
  alias AssistantLink.Events.TextMessage
  alias AssistantLink.Links.Link
  alias AssistantLink.Mailer

  @do_not_reply "Do not reply to this email: nobody reads the replies. Answer the user with `al send`."

  @doc "Sends the Link's wake email address the URL that confirms it. The Link's Assistant must be loaded."
  @spec deliver_confirmation(Link.t(), String.t()) :: {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_confirmation(%Link{} = link, url) do
    deliver(link, ~s(Confirm wake emails for "#{link.assistant.name}" on Assistant Link), """
    An agent connected to the assistant "#{link.assistant.name}" on Assistant Link asked to be woken up at this \
    address when the user writes to it or starts a call.

    To allow this, open the link below and press Confirm, or run:

    curl -X POST #{url}

    #{url}

    The link works for 24 hours. Until it is used, Assistant Link sends nothing else to this address. If you did \
    not expect this email, ignore it.

    #{@do_not_reply}
    """)
  end

  @doc """
  Wakes the Link's agent for a `text_message` (quoting its text) or `call_started` event. The Link's
  Assistant must be loaded.
  """
  @spec deliver_wake(Link.t(), Event.t()) :: {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_wake(%Link{} = link, %Event{type: :text_message, text_message: %TextMessage{text: text}}) do
    deliver(link, "New message for #{link.assistant.name} on Assistant Link", """
    The user sent "#{link.assistant.name}" this message on Assistant Link:

    #{quote_lines(text)}

    Newer messages may have arrived since this email was sent, so run `al read` to get all of them, and answer \
    each with `al send`.

    #{@do_not_reply}

    Link: #{link.id}
    """)
  end

  def deliver_wake(%Link{} = link, %Event{type: :call_started}) do
    deliver(link, "Call started with #{link.assistant.name} on Assistant Link", """
    The user started a call with "#{link.assistant.name}" on Assistant Link.

    Run `al read`. If it shows a `call_started` without a later `call_ended`, run `al call` to join the call; \
    otherwise answer each message with `al send`.

    #{@do_not_reply}

    Link: #{link.id}
    """)
  end

  defp quote_lines(text), do: text |> String.split(~r/\R/) |> Enum.map_join("\n", &String.trim_trailing("> " <> &1))

  defp deliver(link, subject, body) do
    email =
      new()
      |> to(link.wake_email)
      |> from({"Assistant Link", Application.fetch_env!(:assistant_link, __MODULE__)[:from]})
      |> subject(subject)
      |> header("Auto-Submitted", "auto-generated")
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email), do: {:ok, email}
  end
end
