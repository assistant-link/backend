defmodule AssistantLink.Repo.Migrations.AddAccountsDeletedAt do
  @moduledoc false
  use Ecto.Migration

  # Log out sets deleted_at; the purge finds accounts by it. Existing accounts stay null.
  #
  # The table has one row per app install, so the index builds in moments.
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  def change do
    alter table(:accounts) do
      add :deleted_at, :utc_datetime_usec
    end

    create index(:accounts, [:deleted_at])
  end
end
