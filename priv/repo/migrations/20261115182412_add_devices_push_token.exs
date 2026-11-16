defmodule AssistantLink.Repo.Migrations.AddDevicesPushToken do
  @moduledoc false
  use Ecto.Migration

  # The table has one row per app install, so the index builds in moments.
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  def change do
    alter table(:devices) do
      add :push_token, :text
    end

    create unique_index(:devices, [:push_token])
  end
end
