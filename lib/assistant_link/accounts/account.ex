defmodule AssistantLink.Accounts.Account do
  @moduledoc """
  The tenant: owns Assistants and, through them, Assistant Links. Users belong to it through memberships.
  """
  use AssistantLink.Schema

  @type t :: %__MODULE__{}

  schema "accounts" do
    field :deleted_at, :utc_datetime_usec

    has_many :memberships, AssistantLink.Accounts.Membership
    has_many :assistants, AssistantLink.Assistants.Assistant

    timestamps(updated_at: false)
  end
end
