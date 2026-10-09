defmodule AssistantLink.Assistants.Assistant do
  @moduledoc """
  The user-facing identity of an AI assistant: a name and a preset avatar id (`avatar-1` … `avatar-10`).
  """
  use AssistantLink.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @avatars for n <- 1..10, do: "avatar-#{n}"

  schema "assistants" do
    field :name, :string
    field :avatar, :string

    belongs_to :account, AssistantLink.Accounts.Account
    has_many :links, AssistantLink.Links.Link

    timestamps(updated_at: false)
  end

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(assistant, attrs) do
    assistant
    |> cast(attrs, [:name, :avatar])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :avatar])
    |> validate_length(:name, max: 50)
    |> AssistantLink.Schema.validate_single_line(:name)
    |> validate_inclusion(:avatar, @avatars)
  end
end
