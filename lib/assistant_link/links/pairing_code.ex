defmodule AssistantLink.Links.PairingCode do
  @moduledoc """
  A short-lived, single-use code that pairs one Assistant Link.
  """
  use AssistantLink.Schema

  @type t :: %__MODULE__{}

  schema "pairing_codes" do
    field :code_hash, :binary, redact: true
    field :expires_at, :utc_datetime_usec
    field :used_at, :utc_datetime_usec

    belongs_to :account, AssistantLink.Accounts.Account
    belongs_to :link, AssistantLink.Links.Link

    timestamps(updated_at: false)
  end
end
