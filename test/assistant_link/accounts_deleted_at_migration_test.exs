defmodule AssistantLink.AccountsDeletedAtMigrationTest do
  use AssistantLink.DataCase, async: false

  import AssistantLink.AccountsFixtures
  import AssistantLink.MigrationHelper

  setup_all do
    %{migration: load("20261025140000_add_accounts_deleted_at.exs")}
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

  test "adds a nullable deleted_at with an index, rolls back, and leaves existing accounts null", %{
    migration: migration
  } do
    user_fixture()

    migrate(migration, :down)
    assert deleted_at_column() == []
    assert deleted_at_indexes() == []

    migrate(migration, :up)

    assert deleted_at_column() == [["timestamp without time zone", "YES"]]
    assert deleted_at_indexes() == [["accounts_deleted_at_index"]]
    assert Repo.query!("SELECT count(*) FROM accounts").rows != [[0]]
    assert Repo.query!("SELECT count(*) FROM accounts WHERE deleted_at IS NOT NULL").rows == [[0]]
  end
end
