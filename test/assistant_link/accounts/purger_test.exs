defmodule AssistantLink.Accounts.PurgerTest do
  # The Purger runs in its own process, which shares the test's database connection only in the
  # sandbox's shared mode.
  use AssistantLink.DataCase, async: false

  import AssistantLink.AccountsFixtures

  alias AssistantLink.Accounts.Account
  alias AssistantLink.Accounts.Purger

  defp deleted_account(days_ago) do
    scope = user_scope_fixture()
    delete_account_fixture(scope, days_ago)
    scope.account
  end

  test "runs the first purge shortly after it starts" do
    expired = deleted_account(61)
    pid = start_supervised!({Purger, first_delay: 100})
    :erlang.trace(pid, true, [:receive])

    assert_receive {:trace, ^pid, :receive, :purge}, 5_000
    _ = :sys.get_state(pid)

    refute Repo.get(Account, expired.id)
  end

  test "purges the accounts past the grace period when it runs" do
    expired = deleted_account(61)
    recent = deleted_account(1)
    pid = start_supervised!(Purger)

    send(pid, :purge)
    _ = :sys.get_state(pid)

    refute Repo.get(Account, expired.id)
    assert Repo.get(Account, recent.id)
  end
end
