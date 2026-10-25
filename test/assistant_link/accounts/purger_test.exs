defmodule AssistantLink.Accounts.PurgerTest do
  # The Purger runs in its own process, which shares the test's database connection only in the
  # sandbox's shared mode.
  use AssistantLink.DataCase, async: false

  alias AssistantLink.Accounts
  alias AssistantLink.Accounts.Account
  alias AssistantLink.Accounts.Purger

  defp deleted_account(days_ago) do
    {:ok, %{credential: credential}} = Accounts.register_device()
    scope = Accounts.get_scope_by_device_token(credential)
    :ok = Accounts.delete_account(scope)

    Repo.update_all(from(a in Account, where: a.id == ^scope.account.id),
      set: [deleted_at: DateTime.shift(DateTime.utc_now(), day: -days_ago)]
    )

    scope.account
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
