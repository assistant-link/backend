defmodule AssistantLink.Repo.Migrations.CreateCalls do
  @moduledoc false
  use Ecto.Migration

  # A call and its transcript. `event_id` is the call's `voice_call` event. The partial unique index keeps an
  # Assistant to one call that has not ended. The new tables are empty, so their indexes and keys lock no live data.
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  # excellent_migrations:safety-assured-for-this-file column_reference_added
  def change do
    create table(:calls, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :account_id, :binary_id, null: false
      add :assistant_id, references(:assistants, type: :binary_id, with: [account_id: :account_id]), null: false
      add :event_id, references(:assistant_events, type: :binary_id, with: [account_id: :account_id]), null: false
      add :mode, :text, null: false
      add :started_at, :utc_datetime_usec, null: false
      add :ended_at, :utc_datetime_usec
      add :ended_by, :text
    end

    create unique_index(:calls, [:account_id, :id])
    create unique_index(:calls, [:event_id])
    create unique_index(:calls, [:assistant_id], where: "ended_at IS NULL", name: :calls_open_assistant_id_index)

    create table(:call_transcript_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :account_id, :binary_id, null: false
      add :call_id, references(:calls, type: :binary_id, with: [account_id: :account_id]), null: false
      add :seq, :integer, null: false
      add :speaker, :text, null: false
      add :text, :text, null: false
      add :started_at, :utc_datetime_usec, null: false
      add :ended_at, :utc_datetime_usec
    end

    create unique_index(:call_transcript_entries, [:call_id, :seq])
    create index(:call_transcript_entries, [:account_id])
  end
end
