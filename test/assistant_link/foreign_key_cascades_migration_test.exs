defmodule AssistantLink.ForeignKeyCascadesMigrationTest do
  # The schema changes are visible to every connection, so the sandbox runs in shared mode.
  use AssistantLink.DataCase, async: false

  import AssistantLink.AccountsFixtures

  alias AssistantLink.Accounts.Account

  @version 20_261_025_140_100
  @migration Application.app_dir(:assistant_link, "priv/repo/migrations/20261025140100_remove_foreign_key_cascades.exs")

  @cascading_keys [
    "users_tokens_user_id_fkey",
    "memberships_account_id_fkey",
    "memberships_user_id_fkey",
    "devices_user_id_fkey",
    "assistants_account_id_fkey",
    "assistant_links_assistant_id_fkey",
    "pairing_codes_link_id_fkey"
  ]

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

  defp foreign_keys(delete_action) do
    sql = "SELECT conname, convalidated FROM pg_constraint WHERE contype = 'f' AND confdeltype = $1 ORDER BY conname"
    Repo.query!(sql, [delete_action]).rows
  end

  test "leaves no foreign key with an ON DELETE action and keeps the names" do
    assert foreign_keys("c") == []

    names = Enum.map(foreign_keys("a"), &hd/1)
    assert Enum.all?(@cascading_keys, &(&1 in names))
  end

  test "rolls back to the seven cascades and migrates again with the data kept", %{migration: migration} do
    user = user_fixture()
    account = owned_account(user)

    migrate(migration, :down)

    assert "c" |> foreign_keys() |> Enum.map(&hd/1) |> Enum.sort() == Enum.sort(@cascading_keys)
    assert Enum.all?(foreign_keys("c"), &match?([_, true], &1))

    migrate(migration, :up)

    assert foreign_keys("c") == []
    assert Enum.all?(foreign_keys("a"), &match?([_, true], &1))
    assert Repo.get!(Account, account.id)
  end
end
