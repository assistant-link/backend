defmodule AssistantLink.AccountsFixtures do
  @moduledoc """
  Test data for users, their accounts, and devices, created through `AssistantLink.Accounts` so every
  user gets an account and owner membership as in production.
  """

  # Test support shared by core and web tests, unchecked like AssistantLink.DataCase.
  use Boundary, top_level?: true, check: [in: false, out: false]

  import Ecto.Query

  alias AssistantLink.Accounts
  alias AssistantLink.Accounts.Account

  def unique_user_email, do: "user#{System.unique_integer()}@example.com"
  def valid_user_password, do: "hello world!"

  def valid_user_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      email: unique_user_email()
    })
  end

  def unconfirmed_user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> valid_user_attributes()
      |> Accounts.register_user()

    user
  end

  def user_fixture(attrs \\ %{}) do
    user = unconfirmed_user_fixture(attrs)

    token =
      extract_user_token(fn url ->
        Accounts.deliver_login_instructions(user, url)
      end)

    {:ok, {user, _expired_tokens}} =
      Accounts.login_user_by_magic_link(token)

    user
  end

  def user_scope_fixture do
    user = user_fixture()
    user_scope_fixture(user)
  end

  def user_scope_fixture(user) do
    Accounts.scope_for_user(user)
  end

  @doc """
  The account a fixture user owns. Fixture users are registered here, so each owns exactly one.
  """
  def owned_account(user) do
    AssistantLink.Repo.one!(
      from a in Account,
        join: m in AssistantLink.Accounts.Membership,
        on: m.account_id == a.id,
        where: m.user_id == ^user.id and m.role == :owner
    )
  end

  @doc "Creates a device for `user` acting in `account` and returns it with its raw account credential."
  def device_fixture(user, account \\ nil) do
    token = AssistantLink.Tokens.generate(:account)

    device =
      AssistantLink.Repo.insert!(%AssistantLink.Accounts.Device{
        account_id: (account || owned_account(user)).id,
        user_id: user.id,
        token_hash: AssistantLink.Tokens.hash(token)
      })

    {device, token}
  end

  @doc "Deletes the scope's account as a log out does, then backdates `deleted_at` by `days` days."
  def delete_account_fixture(scope, days) do
    :ok = Accounts.delete_account(scope)

    AssistantLink.Repo.update_all(from(a in Account, where: a.id == ^scope.account.id),
      set: [deleted_at: DateTime.shift(DateTime.utc_now(), day: -days)]
    )
  end

  def set_password(user) do
    {:ok, {user, _expired_tokens}} =
      Accounts.update_user_password(user, %{password: valid_user_password()})

    user
  end

  def extract_user_token(fun) do
    {:ok, captured_email} = fun.(&"[TOKEN]#{&1}[TOKEN]")
    [_, token | _] = String.split(captured_email.text_body, "[TOKEN]")
    token
  end

  def override_token_authenticated_at(token, authenticated_at) when is_binary(token) do
    AssistantLink.Repo.update_all(
      from(t in Accounts.UserToken,
        where: t.token == ^token
      ),
      set: [authenticated_at: authenticated_at]
    )
  end

  def generate_user_magic_link_token(user) do
    {encoded_token, user_token} = Accounts.UserToken.build_email_token(user, "login")
    AssistantLink.Repo.insert!(user_token)
    {encoded_token, user_token.token}
  end

  def offset_user_token(token, amount_to_add, unit) do
    dt = DateTime.add(DateTime.utc_now(:second), amount_to_add, unit)

    AssistantLink.Repo.update_all(
      from(ut in Accounts.UserToken, where: ut.token == ^token),
      set: [inserted_at: dt, authenticated_at: dt]
    )
  end
end
