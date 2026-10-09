defmodule AssistantLink.Accounts.Device do
  @moduledoc """
  An app install, acting as one user in one account. It holds the account credential the app sends as
  its bearer token, and exists only while that user's membership in the account does.
  """
  use AssistantLink.Schema

  @type t :: %__MODULE__{}

  schema "devices" do
    field :token_hash, :binary, redact: true
    field :last_seen_at, :utc_datetime_usec

    belongs_to :account, AssistantLink.Accounts.Account
    belongs_to :user, AssistantLink.Accounts.User

    timestamps(updated_at: false)
  end
end
