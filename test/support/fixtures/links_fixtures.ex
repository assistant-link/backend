defmodule AssistantLink.LinksFixtures do
  @moduledoc """
  Test data for Assistants and their Links, created through the contexts as the API does.
  """

  use Boundary, top_level?: true, check: [in: false, out: false]

  alias AssistantLink.Assistants
  alias AssistantLink.Events
  alias AssistantLink.Links

  @doc "Creates an Assistant with a Link paired through a pairing code, and returns the Link and its token."
  def paired_link_fixture(scope, assistant_name \\ "Hermes") do
    {:ok, assistant} = Assistants.create_assistant(scope, %{"name" => assistant_name, "avatar" => "avatar-1"})
    another_paired_link_fixture(scope, assistant)
  end

  @doc "Stores a user's text message to the Assistant and returns its event."
  def user_message_fixture(scope, assistant, text \\ "Hi") do
    params = %{"text" => text, "idempotency_key" => Ecto.UUID.generate(version: 7)}
    {:ok, event, :created} = Events.create_text_message(scope, assistant.id, params)
    event
  end

  @doc "Pairs a new Link for an existing Assistant, and returns the Link and its token."
  def another_paired_link_fixture(scope, assistant) do
    {:ok, link} = Links.create_link(scope, assistant.id, %{})
    {:ok, %{code: code}} = Links.issue_pairing_code(scope, link.id)
    {:ok, %{link: link, token: token}} = Links.pair(code)
    {link, token}
  end
end
