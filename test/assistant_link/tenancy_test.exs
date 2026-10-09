defmodule AssistantLink.TenancyTest do
  use AssistantLink.DataCase, async: true

  import AssistantLink.AccountsFixtures

  alias AssistantLink.Accounts
  alias AssistantLink.Accounts.Account
  alias AssistantLink.Accounts.Device
  alias AssistantLink.Accounts.Membership
  alias AssistantLink.Accounts.Scope
  alias AssistantLink.Accounts.User
  alias AssistantLink.Accounts.UserToken
  alias AssistantLink.Assistants.Assistant
  alias AssistantLink.Links.Link
  alias AssistantLink.Links.PairingCode

  defp assistant_with_link(account) do
    assistant = Repo.insert!(%Assistant{account_id: account.id, name: "Hermes", avatar: "avatar-1"})
    link = Repo.insert!(%Link{account_id: account.id, assistant_id: assistant.id, label: "laptop"})

    Repo.insert!(%PairingCode{
      account_id: account.id,
      link_id: link.id,
      code_hash: :crypto.strong_rand_bytes(32),
      expires_at: DateTime.shift(DateTime.utc_now(), minute: 15)
    })

    {assistant, link}
  end

  defp user_with_data do
    user = user_fixture()
    account = owned_account(user)

    device_fixture(user)
    Accounts.generate_user_session_token(user)
    assistant_with_link(account)

    {user, account}
  end

  defp counts do
    for schema <- [User, UserToken, Device, Membership, Account, Assistant, Link, PairingCode], into: %{} do
      {schema, Repo.aggregate(schema, :count)}
    end
  end

  test "registering a user creates an account they own" do
    user = user_fixture()

    assert [%Membership{role: :owner, account_id: account_id}] =
             Repo.all(from m in Membership, where: m.user_id == ^user.id)

    assert Repo.get!(Account, account_id)
  end

  test "ids are UUIDv7" do
    {user, account} = user_with_data()

    for id <- [user.id, account.id] do
      assert <<_::binary-size(14), "7", _::binary>> = id
    end
  end

  describe "a device credential" do
    test "scopes requests to the device's user and account" do
      user = user_fixture()
      {_device, token} = device_fixture(user)

      assert %Scope{user: %User{id: user_id}, account: %Account{id: account_id}} =
               Accounts.get_scope_by_device_token(token)

      assert user_id == user.id
      assert account_id == owned_account(user).id
    end

    test "acts in the account it was issued for when the user belongs to several" do
      user = user_fixture()
      first_account = owned_account(user)
      second_account = Repo.insert!(%Account{})
      Repo.insert!(%Membership{account_id: second_account.id, user_id: user.id, role: :owner})

      {_device, first_token} = device_fixture(user, first_account)
      {_device, second_token} = device_fixture(user, second_account)

      assert Accounts.get_scope_by_device_token(first_token).account.id == first_account.id
      assert Accounts.get_scope_by_device_token(second_token).account.id == second_account.id
    end

    test "cannot exist without a membership for its user and account" do
      user = user_fixture()
      stranger_account = Repo.insert!(%Account{})

      assert_raise Ecto.ConstraintError, fn -> device_fixture(user, stranger_account) end
    end
  end

  describe "tenancy constraints" do
    test "a Link cannot reference another account's Assistant" do
      {_user, account} = user_with_data()
      {_other_user, other_account} = user_with_data()
      {other_assistant, _link} = assistant_with_link(other_account)

      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%Link{account_id: account.id, assistant_id: other_assistant.id})
      end
    end

    test "a pairing code cannot reference another account's Link" do
      {_user, account} = user_with_data()
      {_other_user, other_account} = user_with_data()
      {_assistant, other_link} = assistant_with_link(other_account)

      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%PairingCode{
          account_id: account.id,
          link_id: other_link.id,
          code_hash: :crypto.strong_rand_bytes(32),
          expires_at: DateTime.utc_now()
        })
      end
    end
  end

  describe "cascades" do
    test "deleting an account deletes its memberships, devices, Assistants, Links, and pairing codes" do
      {_user, account} = user_with_data()
      {other_user, _other_account} = user_with_data()

      Repo.delete!(account)

      assert counts() == %{
               User => 2,
               UserToken => 2,
               Device => 1,
               Membership => 1,
               Account => 1,
               Assistant => 1,
               Link => 1,
               PairingCode => 1
             }

      assert Repo.get(User, other_user.id)
    end

    test "deleting a user deletes their memberships, devices, and user tokens" do
      {user, account} = user_with_data()
      user_with_data()

      Repo.delete!(account)
      Repo.delete!(user)

      assert counts() == %{
               User => 1,
               UserToken => 1,
               Device => 1,
               Membership => 1,
               Account => 1,
               Assistant => 1,
               Link => 1,
               PairingCode => 1
             }
    end

    test "deleting a membership deletes the devices acting through it" do
      {user, account} = user_with_data()
      Repo.insert!(%Membership{account_id: account.id, user_id: user_fixture().id, role: :owner})

      Repo.delete_all(from m in Membership, where: m.user_id == ^user.id and m.account_id == ^account.id)

      assert Repo.aggregate(from(d in Device, where: d.user_id == ^user.id), :count) == 0
      assert Repo.get(User, user.id)
    end
  end

  describe "every account keeps an owner" do
    # The rule is checked at commit and test transactions never commit, so each test checks it here.
    defp check_now!, do: Repo.query!("SET CONSTRAINTS ALL IMMEDIATE")

    test "an account cannot be created without an owner" do
      Repo.insert!(%Account{})

      assert_raise Postgrex.Error, ~r/has no owner/, &check_now!/0
    end

    test "registering a user satisfies it" do
      user_fixture()

      assert %Postgrex.Result{} = check_now!()
    end

    test "an account's only owner cannot be deleted while the account exists" do
      user = user_fixture()
      Repo.delete!(user)

      assert_raise Postgrex.Error, ~r/has no owner/, &check_now!/0
    end

    test "deleting the account first lets its only owner be deleted" do
      user = user_fixture()
      Repo.delete!(owned_account(user))
      Repo.delete!(user)

      assert %Postgrex.Result{} = check_now!()
    end

    test "an owner can leave an account that has another owner" do
      user = user_fixture()
      account = owned_account(user)
      Repo.insert!(%Membership{account_id: account.id, user_id: user_fixture().id, role: :owner})
      Repo.delete_all(from m in Membership, where: m.user_id == ^user.id)

      assert %Postgrex.Result{} = check_now!()
    end
  end

  describe "scope_for_user/1" do
    test "scopes a signed-in user to the account of their membership" do
      user = user_fixture()

      assert %Scope{user: %User{id: user_id}, account: %Account{id: account_id}} = Accounts.scope_for_user(user)
      assert user_id == user.id
      assert account_id == owned_account(user).id
    end

    test "raises for a user with more than one membership" do
      user = user_fixture()
      second_account = Repo.insert!(%Account{})
      Repo.insert!(%Membership{account_id: second_account.id, user_id: user.id, role: :owner})

      assert_raise Ecto.MultipleResultsError, fn -> Accounts.scope_for_user(user) end
    end

    test "returns nil for no user" do
      assert Accounts.scope_for_user(nil) == nil
    end
  end
end
