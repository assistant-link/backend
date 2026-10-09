defmodule AssistantLink.Repo.Migrations.RequireAccountOwner do
  @moduledoc false
  use Ecto.Migration

  # Every account must keep an owner, or its Assistants become unreachable while their agents stay
  # connected. The check is deferred to commit, so one transaction can create an account and its owner,
  # or delete an account (cascading to its memberships) and then its users, in either order.
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  def change do
    execute(
      """
      CREATE FUNCTION assert_account_has_owner() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE
        checked_account_id uuid;
      BEGIN
        IF TG_TABLE_NAME = 'accounts' THEN
          checked_account_id := NEW.id;
        ELSE
          checked_account_id := OLD.account_id;
        END IF;

        IF EXISTS (SELECT 1 FROM accounts WHERE id = checked_account_id)
           AND NOT EXISTS (
             SELECT 1 FROM memberships WHERE account_id = checked_account_id AND role = 'owner'
           ) THEN
          RAISE EXCEPTION 'account % has no owner', checked_account_id
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        RETURN NULL;
      END
      $$
      """,
      "DROP FUNCTION assert_account_has_owner()"
    )

    execute(
      """
      CREATE CONSTRAINT TRIGGER account_has_owner_on_insert
        AFTER INSERT ON accounts
        DEFERRABLE INITIALLY DEFERRED
        FOR EACH ROW EXECUTE FUNCTION assert_account_has_owner()
      """,
      "DROP TRIGGER account_has_owner_on_insert ON accounts"
    )

    execute(
      """
      CREATE CONSTRAINT TRIGGER account_keeps_owner
        AFTER DELETE OR UPDATE OF account_id, role ON memberships
        DEFERRABLE INITIALLY DEFERRED
        FOR EACH ROW EXECUTE FUNCTION assert_account_has_owner()
      """,
      "DROP TRIGGER account_keeps_owner ON memberships"
    )
  end
end
