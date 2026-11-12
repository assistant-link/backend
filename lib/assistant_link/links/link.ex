defmodule AssistantLink.Links.Link do
  @moduledoc """
  An Assistant Link: one agent installation connected to an Assistant. It is paired once, which gives
  the agent its Link token. `last_read_seq` is the `seq` of the last event it acknowledged.
  """
  use AssistantLink.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @type status :: :not_paired | :online | :idle | :offline

  schema "assistant_links" do
    field :label, :string
    field :token_hash, :binary, redact: true
    field :paired_at, :utc_datetime_usec
    field :last_active_at, :utc_datetime_usec
    field :last_read_seq, :integer, default: 0
    field :webhook_url, :string
    field :webhook_authorization, :string, redact: true
    field :webhook_pinged_at, :utc_datetime_usec

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

  @doc ~s(Sets or replaces the webhook. Params are `"url"` and an optional `"authorization"`, cleared when absent.)
  @spec webhook_changeset(t(), map()) :: Ecto.Changeset.t()
  def webhook_changeset(link, params) do
    attrs = %{webhook_url: params["url"], webhook_authorization: params["authorization"]}

    link
    |> cast(attrs, [:webhook_url, :webhook_authorization])
    |> validate_required(:webhook_url)
    |> validate_length(:webhook_url, max: 2048, count: :bytes)
    |> validate_length(:webhook_authorization, max: 4096, count: :bytes)
    |> validate_change(:webhook_url, &validate_url/2)
    |> validate_format(:webhook_authorization, ~r/\A[^\p{Cc}]*\z/u, message: "must not contain control characters")
  end

  defp validate_url(:webhook_url, url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and host not in [nil, ""] -> []
      _other -> [webhook_url: "must be an absolute http or https URL"]
    end
  end
end
