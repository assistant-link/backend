defmodule AssistantLink.Repo.Migrations.RemoveForeignKeyCascades do
  @moduledoc false
  use Ecto.Migration

  # No foreign key may delete rows by itself: the purge deletes children explicitly, so a forgotten
  # child fails loudly. Each key is replaced by a copy without ON DELETE: added NOT VALID, validated,
  # then swapped in under the old name. Rolling back restores ON DELETE CASCADE the same way.
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  @cascading_keys ~w(
    users_tokens_user_id_fkey
    memberships_account_id_fkey
    memberships_user_id_fkey
    devices_user_id_fkey
    assistants_account_id_fkey
    assistant_links_assistant_id_fkey
    pairing_codes_link_id_fkey
  )

  def up, do: replace_keys("replace(key.definition, ' ON DELETE CASCADE', '')")
  def down, do: replace_keys("key.definition || ' ON DELETE CASCADE'")

  defp replace_keys(new_definition) do
    names = Enum.map_join(@cascading_keys, ", ", &"'#{&1}'")

    execute("""
    DO $$
    DECLARE
      key record;
    BEGIN
      FOR key IN
        SELECT conrelid::regclass AS table_name, conname, pg_get_constraintdef(oid) AS definition
        FROM pg_constraint
        WHERE contype = 'f' AND conname IN (#{names})
      LOOP
        EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I %s NOT VALID',
                       key.table_name, key.conname || '_new', #{new_definition});
        EXECUTE format('ALTER TABLE %s VALIDATE CONSTRAINT %I', key.table_name, key.conname || '_new');
        EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', key.table_name, key.conname);
        EXECUTE format('ALTER TABLE %s RENAME CONSTRAINT %I TO %I',
                       key.table_name, key.conname || '_new', key.conname);
      END LOOP;
    END
    $$
    """)
  end
end
