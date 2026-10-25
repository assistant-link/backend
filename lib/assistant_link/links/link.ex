defmodule AssistantLink.Links.Link do
  @moduledoc """
  An Assistant Link: one agent installation connected to an Assistant. It is paired once, which gives
  the agent its Link token. `last_read_seq` is the `seq` of the last event it acknowledged.
  """
  use AssistantLink.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @type status :: :not_paired | :online | :offline

  schema "assistant_links" do
    field :label, :string
    field :token_hash, :binary, redact: true
    field :paired_at, :utc_datetime_usec
    field :last_active_at, :utc_datetime_usec
    field :last_read_seq, :integer, default: 0

    belongs_to :account, AssistantLink.Accounts.Account
    belongs_to :assistant, AssistantLink.Assistants.Assistant
    has_many :pairing_codes, AssistantLink.Links.PairingCode

    timestamps(updated_at: false)
  end

  @doc "A blank label is stored as no label."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(link, attrs) do
    link
    |> cast(attrs, [:label])
    |> update_change(:label, &String.trim/1)
    |> validate_length(:label, max: 50)
    |> AssistantLink.Schema.validate_single_line(:label)
  end
end
