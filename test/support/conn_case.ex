defmodule AssistantLinkWeb.ConnCase do
  @moduledoc """
  Test case for tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use AssistantLinkWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use AssistantLinkWeb, :verified_routes

      import AssistantLinkWeb.ConnCase
      import Phoenix.ConnTest
      import Plug.Conn

      @endpoint AssistantLinkWeb.Endpoint
    end
  end

  setup tags do
    AssistantLink.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Setup helper that registers and logs in users.

      setup :register_and_log_in_user

  It stores an updated connection and a registered user in the
  test context.
  """
  def register_and_log_in_user(%{conn: conn} = context) do
    user = AssistantLink.AccountsFixtures.user_fixture()
    scope = AssistantLink.AccountsFixtures.user_scope_fixture(user)

    opts =
      context
      |> Map.take([:token_authenticated_at])
      |> Enum.to_list()

    %{conn: log_in_user(conn, user, opts), user: user, scope: scope}
  end

  @doc """
  Logs the given `user` into the `conn`.

  It returns an updated `conn`.
  """
  def log_in_user(conn, user, opts \\ []) do
    token = AssistantLink.Accounts.generate_user_session_token(user)

    maybe_set_token_authenticated_at(token, opts[:token_authenticated_at])

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  @doc """
  Setup helper that registers an app install, as `POST /api/v1/accounts` does, and authenticates
  `conn` with its account credential.

      setup :register_device

  It stores the authenticated connection, the account, its scope, and the credential in the test
  context.
  """
  def register_device(%{conn: conn}) do
    {:ok, %{account: account, credential: credential}} = AssistantLink.Accounts.register_device()
    scope = AssistantLink.Accounts.get_scope_by_device_token(credential)

    %{conn: authenticate_device(conn, credential), account: account, scope: scope, credential: credential}
  end

  def authenticate_device(conn, credential) do
    Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> credential)
  end

  defp maybe_set_token_authenticated_at(_token, nil), do: nil

  defp maybe_set_token_authenticated_at(token, authenticated_at) do
    AssistantLink.AccountsFixtures.override_token_authenticated_at(token, authenticated_at)
  end
end
