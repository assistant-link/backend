defmodule AssistantLink.AccountDeletionTest do
  use AssistantLink.DataCase, async: true

  import AssistantLink.AccountsFixtures
  import AssistantLink.LinksFixtures

  alias AssistantLink.Accounts
  alias AssistantLink.Accounts.Account
  alias AssistantLink.Accounts.Device
  alias AssistantLink.Accounts.Membership
  alias AssistantLink.Accounts.User
  alias AssistantLink.Accounts.UserToken
  alias AssistantLink.Assistants.Assistant
  alias AssistantLink.Events
  alias AssistantLink.Events.Event
  alias AssistantLink.Events.TextMessage
  alias AssistantLink.Links
  alias AssistantLink.Links.Link
  alias AssistantLink.Links.PairingCode

  @owned_by_account [TextMessage, Event, PairingCode, Link, Assistant, Device, Membership]

  # An account with a paired Link, a text message, and an unused pairing code.
  defp populate(scope) do
    {link, link_token} = paired_link_fixture(scope)

    {:ok, _event, :created} =
      Events.create_text_message(scope, link.assistant_id, %{
        "text" => "Hi",
        "idempotency_key" => Ecto.UUID.generate(version: 7, precision: :monotonic)
      })

    {:ok, unpaired} = Links.create_link(scope, link.assistant_id, %{})
    {:ok, %{code: code}} = Links.issue_pairing_code(scope, unpaired.id)

    %{link_token: link_token, code: code}
  end

  defp email_scope do
    user = user_fixture()
    {device, credential} = device_fixture(user)
    scope = user_scope_fixture(user)
    %{scope: scope, user: user, device: device, credential: credential}
  end

  defp anonymous_scope do
    {:ok, %{credential: credential}} = Accounts.register_device()
    scope = Accounts.get_scope_by_device_token(credential)
    %{scope: scope, user: scope.user, credential: credential}
  end

  defp deleted_at(scope), do: Repo.get!(Account, scope.account.id).deleted_at

  defp counts(account_id) do
    account = {Account, Repo.aggregate(from(a in Account, where: a.id == ^account_id), :count)}

    owned =
      for schema <- @owned_by_account do
        {schema, Repo.aggregate(from(r in schema, where: r.account_id == ^account_id), :count)}
      end

    Map.new([account | owned])
  end

  test "the deletion grace period defaults to 60 days" do
    config = Application.fetch_env!(:assistant_link, Accounts)

    assert Keyword.fetch!(config, :deletion_grace_period) == 60 * 24 * 60 * 60
  end

  describe "delete_account/1" do
    setup do
      %{user: user} = context = email_scope()
      :ok = Accounts.subscribe(context.scope.account.id)
      {login_token, _} = generate_user_magic_link_token(user)

      Map.merge(context, %{session_token: Accounts.generate_user_session_token(user), login_token: login_token})
    end

    test "records deleted_at and keeps the data", %{scope: scope} do
      populate(scope)
      before = counts(scope.account.id)

      assert deleted_at(scope) == nil
      assert :ok = Accounts.delete_account(scope)

      assert %DateTime{} = deleted_at(scope)
      assert counts(scope.account.id) == before
      assert Repo.get(User, scope.user.id)
    end

    test "sends :account_deleted", %{scope: scope} do
      :ok = Accounts.delete_account(scope)

      assert_receive :account_deleted
    end

    test "rejects the account's credentials, Link tokens, and pairing codes", context do
      %{link_token: link_token, code: code} = populate(context.scope)

      :ok = Accounts.delete_account(context.scope)

      assert Accounts.get_scope_by_device_token(context.credential) == nil
      assert Links.get_link_by_token(link_token) == nil
      assert Links.pair(code) == {:error, :invalid_code}
    end

    test "rejects a pairing code when the account is deleted after the code was found", context do
      %{code: code} = populate(context.scope)
      scope = context.scope
      test = self()

      # Deletes the account right after pair/1's first lookup, before it locks the Link.
      :telemetry.attach(
        "delete-after-lookup",
        [:assistant_link, :repo, :query],
        fn _event, _measurements, %{query: query}, _config ->
          if self() == test and query =~ "pairing_codes" and Process.get(:deleted) == nil do
            Process.put(:deleted, true)
            send(test, :lookup_done)
            :ok = Accounts.delete_account(scope)
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("delete-after-lookup") end)

      assert Links.pair(code) == {:error, :invalid_code}
      assert_received :lookup_done
      assert Repo.exists?(from c in PairingCode, where: is_nil(c.used_at))
    end

    test "stops the web sessions and magic links of users whose only account it is", context do
      :ok = Accounts.delete_account(context.scope)

      assert Accounts.get_user_by_session_token(context.session_token) == nil
      assert Accounts.get_user_by_magic_link_token(context.login_token) == nil
      assert Accounts.scope_for_user(context.user) == nil
    end

    test "keeps the sessions of a user who is also in another account", context do
      other_account = Repo.insert!(%Account{})
      Repo.insert!(%Membership{account_id: other_account.id, user_id: context.user.id, role: :owner})

      :ok = Accounts.delete_account(context.scope)

      assert {%User{}, _inserted_at} = Accounts.get_user_by_session_token(context.session_token)
      assert %User{} = Accounts.get_user_by_magic_link_token(context.login_token)
    end

    test "rejects an account that is already deleted and keeps deleted_at", %{scope: scope} do
      :ok = Accounts.delete_account(scope)
      first = deleted_at(scope)
      assert_receive :account_deleted

      assert Accounts.delete_account(scope) == {:error, :unauthorized}

      assert deleted_at(scope) == first
      refute_receive :account_deleted
    end

    test "leaves other accounts alone" do
      other = anonymous_scope()
      populate(other.scope)
      before = counts(other.scope.account.id)

      :ok = Accounts.delete_account(email_scope().scope)

      assert deleted_at(other.scope) == nil
      assert counts(other.scope.account.id) == before
      assert Accounts.get_scope_by_device_token(other.credential)
    end
  end

  describe "purge_deleted_accounts/0" do
    test "deletes the account, everything it owns, and its users with or without an email" do
      with_email = email_scope()
      anonymous = anonymous_scope()

      for %{scope: scope} <- [with_email, anonymous] do
        populate(scope)
        delete_account_fixture(scope, 61)
        Accounts.generate_user_session_token(scope.user)
      end

      other = anonymous_scope()
      populate(other.scope)
      before = counts(other.scope.account.id)
      users_before = Repo.aggregate(User, :count)

      assert :ok = Accounts.purge_deleted_accounts()

      for %{scope: scope, user: user} <- [with_email, anonymous] do
        assert counts(scope.account.id) == Map.new([Account | @owned_by_account], &{&1, 0})
        refute Repo.get(User, user.id)
        assert Repo.aggregate(from(t in UserToken, where: t.user_id == ^user.id), :count) == 0
      end

      assert counts(other.scope.account.id) == before
      assert Repo.aggregate(User, :count) == users_before - 2
      assert Repo.get(User, other.user.id)
      assert %Postgrex.Result{} = Repo.query!("SET CONSTRAINTS ALL IMMEDIATE")
    end

    test "keeps a user who is still in another account" do
      doomed = anonymous_scope()
      shared = email_scope()
      Repo.insert!(%Membership{account_id: doomed.scope.account.id, user_id: shared.user.id, role: :owner})
      Accounts.generate_user_session_token(shared.user)
      delete_account_fixture(doomed.scope, 61)

      assert :ok = Accounts.purge_deleted_accounts()

      refute Repo.get(Account, doomed.scope.account.id)
      refute Repo.get(User, doomed.user.id)
      assert Repo.get(User, shared.user.id)
      assert Repo.get(Account, shared.scope.account.id)
      assert Repo.aggregate(from(t in UserToken, where: t.user_id == ^shared.user.id), :count) > 0
      assert Repo.aggregate(from(m in Membership, where: m.user_id == ^shared.user.id), :count) == 1
    end

    test "keeps accounts within the grace period and accounts that are not deleted" do
      recent = anonymous_scope()
      live = anonymous_scope()
      populate(recent.scope)
      populate(live.scope)
      delete_account_fixture(recent.scope, 59)
      recent_counts = counts(recent.scope.account.id)
      live_counts = counts(live.scope.account.id)

      assert :ok = Accounts.purge_deleted_accounts()

      assert counts(recent.scope.account.id) == recent_counts
      assert counts(live.scope.account.id) == live_counts
      assert Repo.get(User, recent.user.id)
    end
  end
end
