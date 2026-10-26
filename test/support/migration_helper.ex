defmodule AssistantLink.MigrationHelper do
  @moduledoc """
  Runs one migration up or down inside a migration test. Those tests are `async: false`: the schema
  changes are visible to every connection, so the sandbox runs in shared mode.
  """

  # Test support shared by core and web tests, unchecked like AssistantLink.DataCase.
  use Boundary, top_level?: true, check: [in: false, out: false]

  alias AssistantLink.Repo

  @doc "Loads the migration file named `file` and returns what `migrate/2` takes."
  def load(file) do
    [{module, _binary}] = Code.require_file(Application.app_dir(:assistant_link, "priv/repo/migrations/" <> file))
    {file |> String.split("_", parts: 2) |> hd() |> String.to_integer(), module}
  end

  # Without the migration lock, which would hold the one shared sandbox connection the migration needs.
  # Pending deferred owner checks from the test's inserts would make ALTER TABLE fail.
  def migrate(migration, direction) do
    Repo.query!("SET CONSTRAINTS ALL IMMEDIATE")
    Ecto.Migrator.run(Repo, [migration], direction, all: true, log: false, migration_lock: false)
  end
end
