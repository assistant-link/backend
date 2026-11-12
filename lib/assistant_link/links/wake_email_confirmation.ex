defmodule AssistantLink.Links.WakeEmailConfirmation do
  @moduledoc """
  A confirmation email sent to a wake email address, kept for an hour to rate-limit them. The address is
  stored only as a hash of its lowercase form.
  """
  use AssistantLink.Schema

  @type t :: %__MODULE__{}

  schema "wake_email_confirmations" do
    field :address_hash, :binary

    belongs_to :account, AssistantLink.Accounts.Account
    belongs_to :link, AssistantLink.Links.Link

    timestamps(updated_at: false)
  end
end
