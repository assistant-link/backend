defmodule AssistantLinkWeb.WakeEmail do
  @moduledoc """
  Sends wake emails, on the webhook's task supervisor. A new address first gets a link that confirms it: a
  `Phoenix.Token` for the Link and that address, valid for 24 hours, so it works without the Link token and
  stops working once the address changes. A failed send is logged with the Link id only.
  """
  use AssistantLinkWeb, :verified_routes

  alias AssistantLink.Events.Event
  alias AssistantLink.Links
  alias AssistantLink.Links.Link
  alias AssistantLink.Links.WakeNotifier
  alias AssistantLinkWeb.Endpoint

  require Logger

  @salt "wake email confirmation"
  @max_age 24 * 60 * 60

  @doc "Sends the confirmation link for the Link's wake email. The Link's Assistant must be loaded."
  @spec send_confirmation(Link.t()) :: :ok
  def send_confirmation(%Link{} = link) do
    url = url(~p"/wake-email/confirm/#{confirmation_token(link)}")
    start(link, fn -> WakeNotifier.deliver_confirmation(link, url, docs_url()) end)
  end

  @doc "Wakes each Link, claimed with its Assistant, by email for the event."
  @spec send_wakes([Link.t()], Event.t()) :: :ok
  def send_wakes(links, %Event{} = event) do
    Enum.each(links, fn link -> start(link, fn -> WakeNotifier.deliver_wake(link, event, docs_url()) end) end)
  end

  @doc "A token that confirms the Link's current wake email. `opts` go to `Phoenix.Token.sign/4`."
  @spec confirmation_token(Link.t(), keyword()) :: String.t()
  def confirmation_token(%Link{wake_email: address} = link, opts \\ []) when is_binary(address),
    do: Phoenix.Token.sign(Endpoint, @salt, {link.id, address}, opts)

  @doc "The Link a confirmation token is for, if the token is unexpired and the address is still the Link's."
  @spec verify(String.t()) :: {:ok, Link.t()} | {:error, :invalid}
  def verify(token) do
    with {:ok, {link_id, address}} <- verify_token(token),
         %Link{} = link <- Links.get_link_by_wake_email(link_id, address) do
      {:ok, link}
    else
      _expired_forged_or_replaced -> {:error, :invalid}
    end
  end

  @doc "Confirms the wake email a token is for, if it is still the Link's address."
  @spec confirm(String.t()) :: {:ok, Link.t()} | {:error, :invalid}
  def confirm(token) do
    case verify_token(token) do
      {:ok, {link_id, address}} -> Links.confirm_wake_email(link_id, address)
      {:error, _reason} -> {:error, :invalid}
    end
  end

  defp docs_url, do: Endpoint.url() <> "/install.md"

  defp verify_token(token), do: Phoenix.Token.verify(Endpoint, @salt, token, max_age: @max_age)

  defp start(link, deliver) do
    {:ok, _pid} = Task.Supervisor.start_child(AssistantLinkWeb.Webhook.Supervisor, fn -> deliver(link, deliver) end)
    :ok
  end

  # The mailer raises when it is not configured, for example without an API key.
  defp deliver(link, deliver) do
    case deliver.() do
      {:ok, _email} -> :ok
      {:error, reason} -> Logger.warning("Wake email of Link #{link.id} failed: #{inspect(reason)}")
    end
  rescue
    exception -> Logger.warning("Wake email of Link #{link.id} failed: #{Exception.message(exception)}")
  end
end
