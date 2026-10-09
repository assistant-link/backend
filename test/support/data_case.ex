defmodule AssistantLink.DataCase do
  @moduledoc """
  Test case for tests requiring access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use AssistantLink.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  # Test support shared by core and web tests (ConnCase calls setup_sandbox/1).
  # Boundary's docs recommend an unchecked top-level boundary for test support.
  use Boundary, top_level?: true, check: [in: false, out: false]
  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      import AssistantLink.DataCase
      import Ecto
      import Ecto.Changeset
      import Ecto.Query

      alias AssistantLink.Repo
    end
  end

  setup tags do
    AssistantLink.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Sandbox.start_owner!(AssistantLink.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
