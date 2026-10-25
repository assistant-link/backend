defmodule AssistantLink.AccountsDeletedAtMigrationTest do
  # The schema changes are visible to every connection, so the sandbox runs in shared mode.
  use AssistantLink.DataCase, async: false

  import AssistantLink.AccountsFixtures

  @version 20_261_025_140_000
  @migration Application.app_dir(:assistant_link, "priv/repo/migrations/20261025140000_add_accounts_deleted_at.exs")

  setup_all do
    [{module, _binary}] = Code.require_file(@migration)
    %{migration: module}
  end

  # Without the migration lock, which would hold the one shared sandbox connection the migration needs.
  # Pending deferred owner checks from the test's inserts would make ALTER TABLE fail.
  defp migrate(module, direction) do
    Repo.query!("SET CONSTRAINTS ALL IMMEDIATE")
    Ecto.Migrator.run(Repo, [{@version, module}], direction, all: true, log: false, migration_lock: false)
  end

  defp deleted_at_column do
    sql = """
    SELECT data_type, is_nullable FROM information_schema.columns
    WHERE table_name = 'accounts' AND column_name = 'deleted_at'
    """

    Repo.query!(sql).rows
  end

  defp deleted_at_indexes do
    Repo.query!("SELECT indexname FROM pg_indexes WHERE tablename = 'accounts' AND indexdef LIKE '%(deleted_at)%'").rows
  end

  test "adds a nullable deleted_at with an index and rolls back", %{migration: migration} do
    migrate(migration, :down)
    assert deleted_at_column() == []
    assert deleted_at_indexes() == []

    migrate(migration, :up)

    assert deleted_at_column() == [["timestamp without time zone", "YES"]]
    assert deleted_at_indexes() == [["accounts_deleted_at_index"]]
  end

  test "existing accounts stay null", %{migration: migration} do
    user_fixture()
    migrate(migration, :down)
    migrate(migration, :up)

    assert Repo.query!("SELECT count(*) FROM accounts").rows != [[0]]
    assert Repo.query!("SELECT count(*) FROM accounts WHERE deleted_at IS NOT NULL").rows == [[0]]
  end
end
