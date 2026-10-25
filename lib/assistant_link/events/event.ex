defmodule AssistantLink.Events.Event do
  @moduledoc """
  One item of an Assistant's Timeline. `seq` orders the events of one Assistant. A `text_message` whose
  payload was deleted has no `text_message` row.
  """
  use AssistantLink.Schema

  @type t :: %__MODULE__{}

  schema "assistant_events" do
    field :type, Ecto.Enum, values: [:link_created, :text_message]
    field :sender, Ecto.Enum, values: [:user, :assistant, :system]
    field :seq, :integer
    field :delivered_at, :utc_datetime_usec
    field :idempotency_key, Ecto.UUID

    belongs_to :account, AssistantLink.Accounts.Account
    belongs_to :assistant, AssistantLink.Assistants.Assistant
    belongs_to :link, AssistantLink.Links.Link
    has_one :text_message, AssistantLink.Events.TextMessage

    timestamps(updated_at: false)
  end
end
