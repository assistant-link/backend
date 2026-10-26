defmodule AssistantLink.EventsMigrationTest do
  # The schema changes are visible to every connection, so the sandbox runs in shared mode.
  use AssistantLink.DataCase, async: false

  import AssistantLink.AccountsFixtures

  alias Ecto.UUID

  @version 20_261_025_122_706
  @early ~U[2026-01-01 10:00:00.000000Z]
  @early_naive ~N[2026-01-01 10:00:00.000000]
  @late ~U[2026-01-02 10:00:00.000000Z]
  @late_naive ~N[2026-01-02 10:00:00.000000]

  @migration Application.app_dir(:assistant_link, "priv/repo/migrations/20261025122706_create_assistant_events.exs")

  setup_all do
    # `mix test` already migrated in this VM, which loaded the module.
    ignore = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)
    [{module, _binary}] = Code.compile_file(@migration)
    Code.put_compiler_option(:ignore_module_conflict, ignore)
    %{migration: module}
  end

  # Without the migration lock, which would hold the one shared sandbox connection the migration needs.
  defp migrate(module, direction) do
    Ecto.Migrator.run(Repo, [{@version, module}], direction, all: true, log: false, migration_lock: false)
  end

  defp table_exists?(table), do: Repo.query!("SELECT to_regclass($1)", [table]).rows != [[nil]]

  defp column_exists?(table, column) do
    sql = "SELECT 1 FROM information_schema.columns WHERE table_name = $1 AND column_name = $2"
    Repo.query!(sql, [table, column]).num_rows == 1
  end

  # Rows as the previous version of the service wrote them, with no event columns.
  defp insert_old_assistant(account) do
    id = UUID.generate(version: 7)

    Repo.insert_all("assistants", [
      %{
        id: UUID.dump!(id),
        account_id: UUID.dump!(account.id),
        name: "Hermes",
        avatar: "avatar-1",
        inserted_at: DateTime.utc_now()
      }
    ])

    id
  end

  defp insert_old_link(account, assistant_id, id, inserted_at) do
    Repo.insert_all("assistant_links", [
      %{
        id: UUID.dump!(id),
        account_id: UUID.dump!(account.id),
        assistant_id: UUID.dump!(assistant_id),
        inserted_at: inserted_at
      }
    ])
  end

  test "rolls back and migrates again", %{migration: migration} do
    migrate(migration, :down)

    refute table_exists?("assistant_events")
    refute table_exists?("text_messages")
    refute column_exists?("assistants", "last_event_seq")
    refute column_exists?("assistant_links", "last_read_seq")

    migrate(migration, :up)

    assert table_exists?("assistant_events")
    assert table_exists?("text_messages")
    assert column_exists?("assistants", "last_event_seq")
    assert column_exists?("assistant_links", "last_read_seq")
  end

  test "backfills a link_created event per Link, numbered per Assistant by (inserted_at, id)", %{migration: migration} do
    account = owned_account(user_fixture())
    other_account = owned_account(user_fixture())
    migrate(migration, :down)

    assistant_id = insert_old_assistant(account)
    other_assistant_id = insert_old_assistant(other_account)
    empty_assistant_id = insert_old_assistant(account)

    # The two Links created together are ordered by id.
    oldest_id = "01a00000-0000-7000-8000-000000000009"
    low_id = "01a00000-0000-7000-8000-000000000001"
    high_id = "01a00000-0000-7000-8000-000000000002"
    other_id = "01a00000-0000-7000-8000-000000000003"

    insert_old_link(account, assistant_id, high_id, @late)
    insert_old_link(account, assistant_id, low_id, @late)
    insert_old_link(account, assistant_id, oldest_id, @early)
    insert_old_link(other_account, other_assistant_id, other_id, @late)

    migrate(migration, :up)

    events =
      Map.new(
        Repo.query!("SELECT link_id::text, seq, sender, type, inserted_at FROM assistant_events").rows,
        fn [link_id, seq, sender, type, inserted_at] -> {link_id, {seq, sender, type, inserted_at}} end
      )

    assert %{
             ^oldest_id => {1, "system", "link_created", @early_naive},
             ^low_id => {2, "system", "link_created", @late_naive},
             ^high_id => {3, "system", "link_created", @late_naive},
             ^other_id => {1, "system", "link_created", @late_naive}
           } = events

    assert map_size(events) == 4

    assert Map.new(Repo.query!("SELECT id::text, last_event_seq FROM assistants").rows, &List.to_tuple/1) == %{
             assistant_id => 3,
             other_assistant_id => 1,
             empty_assistant_id => 0
           }

    assert Repo.query!("SELECT DISTINCT last_read_seq FROM assistant_links").rows == [[0]]

    [[id]] = Repo.query!("SELECT id::text FROM assistant_events WHERE link_id = $1", [UUID.dump!(oldest_id)]).rows
    assert <<unix_ms::48, 7::4, _rest::bitstring>> = UUID.dump!(id)
    assert unix_ms == DateTime.to_unix(@early, :millisecond)
  end
end
