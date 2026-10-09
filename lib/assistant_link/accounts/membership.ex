defmodule AssistantLink.Accounts.Membership do
  @moduledoc """
  Joins a user to an account with a role.
  """
  use AssistantLink.Schema

  @type t :: %__MODULE__{}

  schema "memberships" do
    field :role, Ecto.Enum, values: [:owner]

    belongs_to :account, AssistantLink.Accounts.Account
    belongs_to :user, AssistantLink.Accounts.User

    timestamps(updated_at: false)
  end
end
