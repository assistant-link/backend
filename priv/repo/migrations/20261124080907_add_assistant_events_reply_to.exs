defmodule AssistantLink.Repo.Migrations.AddAssistantEventsReplyTo do
  @moduledoc false
  use Ecto.Migration

  # The key is added unvalidated, so this lock is not held for a scan of the table; the next migration validates it.
  # excellent_migrations:safety-assured-for-this-file column_reference_added
  def change do
    alter table(:assistant_events) do
      add :reply_to,
          references(:assistant_events, type: :binary_id, with: [account_id: :account_id], validate: false)
    end
  end
end
