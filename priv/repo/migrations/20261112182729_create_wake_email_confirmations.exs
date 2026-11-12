defmodule AssistantLink.Repo.Migrations.CreateWakeEmailConfirmations do
  @moduledoc false
  use Ecto.Migration

  # The new table is empty, so its indexes and keys lock no live data.
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  # excellent_migrations:safety-assured-for-this-file column_reference_added
  def change do
    create table(:wake_email_confirmations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :account_id, :binary_id, null: false
      add :link_id, references(:assistant_links, type: :binary_id, with: [account_id: :account_id]), null: false
      add :address_hash, :binary, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:wake_email_confirmations, [:account_id, :link_id, :inserted_at])
    create index(:wake_email_confirmations, [:address_hash, :inserted_at])
    create index(:wake_email_confirmations, [:inserted_at])
  end
end
