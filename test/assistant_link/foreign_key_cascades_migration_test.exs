defmodule AssistantLink.ForeignKeyCascadesMigrationTest do
  use AssistantLink.DataCase, async: false

  import AssistantLink.AccountsFixtures
  import AssistantLink.MigrationHelper

  alias AssistantLink.Accounts.Account

  @cascading_keys [
    "assistant_links_assistant_id_fkey",
    "assistants_account_id_fkey",
    "devices_user_id_fkey",
    "memberships_account_id_fkey",
    "memberships_user_id_fkey",
    "pairing_codes_link_id_fkey",
    "users_tokens_user_id_fkey"
  ]

  setup_all do
    %{migration: load("20261025140100_remove_foreign_key_cascades.exs")}
  end

  defp foreign_keys(delete_action) do
    sql = "SELECT conname, convalidated FROM pg_constraint WHERE contype = 'f' AND confdeltype = $1 ORDER BY conname"
    Repo.query!(sql, [delete_action]).rows
  end

  test "rolls back to the seven cascades and migrates again with the data kept", %{migration: migration} do
    account = owned_account(user_fixture())

    migrate(migration, :down)

    assert foreign_keys("c") == Enum.map(@cascading_keys, &[&1, true])

    migrate(migration, :up)

    assert foreign_keys("c") == []
    assert Enum.all?(foreign_keys("a"), &match?([_, true], &1))
    assert Repo.get!(Account, account.id)
  end
end
