defmodule AssistantLink.Assistants.Assistant do
  @moduledoc """
  The user-facing identity of an AI assistant: a name, a preset avatar id (`avatar-1` … `avatar-10`), and
  the platform its agent says it runs on, if any. A known platform is stored in lowercase and any other
  verbatim.
  """
  use AssistantLink.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @avatars for n <- 1..10, do: "avatar-#{n}"
  @platforms ~w(muse grokbot dots duet hermes openclaw instinct)

  schema "assistants" do
    field :name, :string
    field :avatar, :string
    field :platform, :string
    field :last_event_seq, :integer, default: 0
    field :latest_event, :any, virtual: true

    belongs_to :account, AssistantLink.Accounts.Account
    has_many :links, AssistantLink.Links.Link

    timestamps(updated_at: false)
  end

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(assistant, attrs) do
    assistant
    |> cast(attrs, [:name, :avatar])
    |> validate_name()
    |> validate_required([:avatar])
    |> validate_inclusion(:avatar, @avatars)
  end

  @doc "The changes an agent can make: its name and platform. Blank clears the platform."
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(assistant, attrs) do
    assistant
    |> cast(attrs, [:name, :platform])
    |> validate_name()
    |> update_change(:platform, &normalize_platform/1)
    |> validate_length(:platform, max: 50)
    |> AssistantLink.Schema.validate_single_line(:platform)
  end

  defp validate_name(changeset) do
    changeset
    |> update_change(:name, &trim/1)
    |> validate_required([:name])
    |> validate_length(:name, max: 50)
    |> AssistantLink.Schema.validate_single_line(:name)
  end

  defp trim(nil), do: nil
  defp trim(text), do: String.trim(text)

  defp normalize_platform(nil), do: nil

  defp normalize_platform(platform) do
    platform = String.trim(platform)
    lowercase = String.downcase(platform)

    cond do
      platform == "" -> nil
      lowercase in @platforms -> lowercase
      true -> platform
    end
  end
end
