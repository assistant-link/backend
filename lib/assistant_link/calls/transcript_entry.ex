defmodule AssistantLink.Calls.TranscriptEntry do
  @moduledoc """
  One utterance of a call. `seq` orders the entries of a call as they were saved, which may differ from the
  order they were spoken in; `started_at` and `ended_at` keep the real timing of overlapping speech. `ended_at`
  is `nil` while the utterance is still being spoken or recognized. `text` may be empty until it is recognized.
  """
  use AssistantLink.Schema

  import Ecto.Changeset

  @max_length 10_000

  @type t :: %__MODULE__{}

  schema "call_transcript_entries" do
    field :seq, :integer
    field :speaker, Ecto.Enum, values: [:user, :assistant]
    field :text, :string
    field :started_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec

    belongs_to :account, AssistantLink.Accounts.Account
    belongs_to :call, AssistantLink.Calls.Call
  end

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(entry, attrs) do
    entry
    |> cast(attrs, [:speaker, :text, :started_at, :ended_at], empty_values: [])
    |> validate_required([:speaker, :started_at])
    |> validate_entry()
  end

  @doc "Changes only `text` and `ended_at`, as recognition or speech finishes."
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(entry, attrs) do
    entry
    |> cast(attrs, [:text, :ended_at], empty_values: [])
    |> validate_entry()
  end

  defp validate_entry(changeset) do
    changeset
    |> validate_text_present()
    |> validate_length(:text, max: @max_length)
    |> validate_format(:text, ~r/\A[^\x00]*\z/u, message: "must not contain U+0000")
    |> validate_ended_at()
  end

  defp validate_text_present(changeset) do
    if is_nil(get_field(changeset, :text)), do: add_error(changeset, :text, "can't be nil"), else: changeset
  end

  defp validate_ended_at(changeset) do
    started_at = get_field(changeset, :started_at)
    ended_at = get_field(changeset, :ended_at)

    if started_at && ended_at && DateTime.before?(ended_at, started_at),
      do: add_error(changeset, :ended_at, "must not be before started_at"),
      else: changeset
  end
end
