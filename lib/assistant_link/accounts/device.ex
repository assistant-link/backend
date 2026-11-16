defmodule AssistantLink.Accounts.Device do
  @moduledoc """
  An app install, acting as one user in one account. It holds the account credential the app sends as
  its bearer token, and exists only while that user's membership in the account does. `push_token` is
  the install's APNs device token, if it registered one; one device at most has a given token.
  """
  use AssistantLink.Schema

  @type t :: %__MODULE__{}

  schema "devices" do
    field :token_hash, :binary, redact: true
    field :last_seen_at, :utc_datetime_usec
    field :push_token, :string

    belongs_to :account, AssistantLink.Accounts.Account
    belongs_to :user, AssistantLink.Accounts.User

    timestamps(updated_at: false)
  end
end
