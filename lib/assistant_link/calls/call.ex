defmodule AssistantLink.Calls.Call do
  @moduledoc """
  A voice call with an Assistant, shown in its Timeline as the `voice_call` event `event_id`. A call is open
  while `ended_at` is `nil`; an Assistant has at most one open call.
  """
  use AssistantLink.Schema

  @type t :: %__MODULE__{}

  schema "calls" do
    field :mode, Ecto.Enum, values: [:realtime_relay, :native]
    field :started_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    field :ended_by, Ecto.Enum, values: [:user, :assistant, :system]

    belongs_to :account, AssistantLink.Accounts.Account
    belongs_to :assistant, AssistantLink.Assistants.Assistant
    belongs_to :event, AssistantLink.Events.Event
  end
end
