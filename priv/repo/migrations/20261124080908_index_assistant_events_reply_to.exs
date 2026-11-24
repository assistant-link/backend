defmodule AssistantLink.Repo.Migrations.IndexAssistantEventsReplyTo do
  @moduledoc false
  use Ecto.Migration

  # The purge deletes events that replies point to; without an index, each deletion scans the table for replies.
  # Validating the key outside the migration that added it blocks no writes while it scans.
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create index(:assistant_events, [:account_id, :reply_to], where: "reply_to IS NOT NULL", concurrently: true)
    execute("ALTER TABLE assistant_events VALIDATE CONSTRAINT assistant_events_reply_to_fkey", "")
  end
end
