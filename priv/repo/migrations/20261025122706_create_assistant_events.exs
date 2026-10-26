defmodule AssistantLink.Repo.Migrations.CreateAssistantEvents do
  @moduledoc false
  use Ecto.Migration

  # The Timeline: one row per event, with a text message's payload in its own table so it can be
  # deleted alone. `seq` orders an Assistant's events and `last_event_seq` is the highest one used.
  # `assistant_links.last_read_seq` is the cursor of the last event a Link acknowledged.
  #
  # The new tables are empty, and a constant default is added to the two existing tables without
  # rewriting them, so nothing here locks live data for long.
  # excellent_migrations:safety-assured-for-this-file column_added_with_default
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  # excellent_migrations:safety-assured-for-this-file column_reference_added
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  def change do
    alter table(:assistants) do
      add :last_event_seq, :bigint, null: false, default: 0
    end

    alter table(:assistant_links) do
      add :last_read_seq, :bigint, null: false, default: 0
    end

    create table(:assistant_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :account_id, :binary_id, null: false

      add :assistant_id, references(:assistants, type: :binary_id, with: [account_id: :account_id]), null: false

      add :type, :text, null: false
      add :sender, :text, null: false

      add :link_id, references(:assistant_links, type: :binary_id, with: [account_id: :account_id])

      add :seq, :bigint, null: false
      add :delivered_at, :utc_datetime_usec
      add :idempotency_key, :binary_id

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:assistant_events, [:account_id, :id])
    create unique_index(:assistant_events, [:assistant_id, :seq])
    create unique_index(:assistant_events, [:account_id, :idempotency_key])
    create index(:assistant_events, [:account_id, :link_id])

    create table(:text_messages, primary_key: false) do
      add :account_id, :binary_id, null: false

      add :event_id,
          references(:assistant_events, type: :binary_id, with: [account_id: :account_id]),
          primary_key: true

      add :text, :text, null: false
    end

    # Each id is a random UUID with its first 48 bits set to the Link's creation time in milliseconds
    # and its version bits to 7.
    execute(
      """
      INSERT INTO assistant_events (id, account_id, assistant_id, type, sender, link_id, seq, inserted_at)
      SELECT encode(
               set_bit(set_bit(
                 overlay(uuid_send(gen_random_uuid()) placing
                   substring(int8send(floor(extract(epoch FROM l.inserted_at AT TIME ZONE 'UTC') * 1000)::bigint) FROM 3)
                   FROM 1 FOR 6),
                 52, 1), 53, 1),
               'hex')::uuid,
             l.account_id, l.assistant_id,
             'link_created', 'system', l.id,
             row_number() OVER (PARTITION BY l.assistant_id ORDER BY l.inserted_at, l.id), l.inserted_at
      FROM assistant_links l
      """,
      ""
    )

    execute(
      """
      UPDATE assistants a SET last_event_seq = e.max_seq
      FROM (SELECT assistant_id, max(seq) AS max_seq FROM assistant_events GROUP BY assistant_id) e
      WHERE a.id = e.assistant_id
      """,
      ""
    )
  end
end
