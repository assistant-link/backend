defmodule AssistantLink.Accounts do
  @moduledoc """
  Users (people), accounts (tenants that own Assistants), the memberships between them, and the
  devices (app installs) that act as a user in an account.
  """

  import Ecto.Query, warn: false

  alias AssistantLink.Accounts.Account
  alias AssistantLink.Accounts.Device
  alias AssistantLink.Accounts.Membership
  alias AssistantLink.Accounts.Scope
  alias AssistantLink.Accounts.User
  alias AssistantLink.Accounts.UserNotifier
  alias AssistantLink.Accounts.UserToken
  alias AssistantLink.Assistants.Assistant
  alias AssistantLink.Events.Event
  alias AssistantLink.Events.TextMessage
  alias AssistantLink.Links.Link
  alias AssistantLink.Links.PairingCode
  alias AssistantLink.Repo
  alias AssistantLink.Tokens

  @doc """
  Returns the scope for a device's account credential: the user and account the device acts as. A
  device exists only while that user's membership in the account does. Returns `nil` if no device has
  the credential, or if its account was deleted. Records that the device was seen, at most once a
  minute.
  """
  @spec get_scope_by_device_token(String.t()) :: Scope.t() | nil
  def get_scope_by_device_token(token) when is_binary(token) do
    query =
      from d in Device,
        join: u in assoc(d, :user),
        join: a in assoc(d, :account),
        where: d.token_hash == ^Tokens.hash(token) and is_nil(a.deleted_at),
        select: {d, u, a}

    case Repo.one(query) do
      {device, user, account} ->
        touch_device(device)
        %Scope{user: user, account: account}

      nil ->
        nil
    end
  end

  @last_seen_resolution_seconds 60

  defp touch_device(%Device{id: id, last_seen_at: last_seen_at}) do
    now = DateTime.utc_now()

    if is_nil(last_seen_at) or DateTime.diff(now, last_seen_at) >= @last_seen_resolution_seconds do
      Repo.update_all(from(d in Device, where: d.id == ^id), set: [last_seen_at: now])
    end
  end

  @doc """
  Returns the scope for a signed-in user: the user acting in the account of their membership.
  Returns `nil` for `nil` or for a user without a membership in an account that is not deleted. Raises
  if the user has more than one, since web sessions have no way to choose an account.
  """
  @spec scope_for_user(User.t() | nil) :: Scope.t() | nil
  def scope_for_user(nil), do: nil

  def scope_for_user(%User{id: user_id} = user) do
    query =
      from a in Account,
        join: m in Membership,
        on: m.account_id == a.id,
        where: m.user_id == ^user_id and is_nil(a.deleted_at)

    case Repo.one(query) do
      %Account{} = account -> %Scope{user: user, account: account}
      nil -> nil
    end
  end

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Gets a user by email and password.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_user_by_email_and_password(email, password) when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)
    if User.valid_password?(user, password), do: user
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  @doc """
  Registers a user, with a new account they own.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_user(attrs) do
    user_changeset = User.email_changeset(%User{}, attrs)

    with {:ok, %{user: user}} <- insert_user_with_account(user_changeset) do
      {:ok, user}
    end
  end

  @doc """
  Registers an app install: an anonymous user (no email) who owns a new account, and a device acting
  in it. Returns the account and the device's account credential, which is not retrievable later.
  """
  @spec register_device() :: {:ok, %{account: Account.t(), credential: String.t()}}
  def register_device do
    credential = Tokens.generate(:account)

    Repo.transact(fn ->
      with {:ok, %{user: user, account: account}} <- insert_user_with_account(Ecto.Changeset.change(%User{})),
           {:ok, _device} <-
             Repo.insert(%Device{account_id: account.id, user_id: user.id, token_hash: Tokens.hash(credential)}) do
        {:ok, %{account: account, credential: credential}}
      end
    end)
  end

  defp insert_user_with_account(user_changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.insert(user_changeset),
           {:ok, account} <- Repo.insert(%Account{}),
           {:ok, _membership} <- Repo.insert(%Membership{account_id: account.id, user_id: user.id, role: :owner}) do
        {:ok, %{user: user, account: account}}
      end
    end)
  end

  @doc """
  Subscribes the caller to its account's events, on every node:

  - `{:link_status, %{link_id: id, status: :online | :offline, last_active_at: DateTime.t()}}` when a
    Link comes online or goes offline
  - `{:event_created, event}` for each stored text message, and `{:event_updated, event}` when a user
    message is first delivered (see `AssistantLink.Events`)
  - `:account_deleted` after the account was deleted
  """
  @spec subscribe(Ecto.UUID.t()) :: :ok
  def subscribe(account_id), do: Phoenix.PubSub.subscribe(AssistantLink.PubSub, topic(account_id))

  @doc false
  @spec topic(Ecto.UUID.t()) :: String.t()
  def topic(account_id), do: "account:" <> account_id

  @doc """
  Soft deletes the scope's account: records `deleted_at`, keeps the data, and sends
  `:account_deleted` to the account's subscribers. From then on the account's credentials, Link
  tokens, and pairing codes stop working, as do the web sessions and magic links of users whose only
  account it is. `purge_deleted_accounts/0` removes the data later.

  Returns `{:error, :unauthorized}` for an account that is already deleted, leaving `deleted_at` as is.
  """
  @spec delete_account(Scope.t()) :: :ok | {:error, :unauthorized}
  def delete_account(%Scope{account: %Account{id: account_id}}) do
    sole_member_ids =
      from m in Membership,
        join: n in Membership,
        on: n.user_id == m.user_id,
        where: m.account_id == ^account_id,
        group_by: m.user_id,
        having: count(n.id) == 1,
        select: m.user_id

    deleted = from a in Account, where: a.id == ^account_id and is_nil(a.deleted_at)

    result =
      Repo.transact(fn ->
        case Repo.update_all(deleted, set: [deleted_at: DateTime.utc_now()]) do
          {1, _} ->
            Repo.delete_all(
              from t in UserToken,
                where: t.user_id in subquery(sole_member_ids) and t.context in ["session", "login"]
            )

            {:ok, :ok}

          {0, _} ->
            {:error, :unauthorized}
        end
      end)

    with {:ok, :ok} <- result do
      Phoenix.PubSub.broadcast(AssistantLink.PubSub, topic(account_id), :account_deleted)
    end
  end

  @doc """
  Permanently deletes every account whose `deleted_at` is older than the `:deletion_grace_period`
  setting, with everything it owns and the users left with no membership. Rows are deleted explicitly,
  children first, one transaction per account. Other accounts are not touched.
  """
  @spec purge_deleted_accounts() :: :ok
  def purge_deleted_accounts do
    config = Application.fetch_env!(:assistant_link, __MODULE__)
    cutoff = DateTime.shift(DateTime.utc_now(), second: -Keyword.fetch!(config, :deletion_grace_period))

    ids = Repo.all(from a in Account, where: a.deleted_at < ^cutoff, select: a.id)
    Enum.each(ids, &purge_account(&1, cutoff))
  end

  @purged_children [TextMessage, Event, PairingCode, Link, Assistant, Device, Membership]

  defp purge_account(account_id, cutoff) do
    Repo.transact(fn ->
      claim =
        from a in Account,
          where: a.id == ^account_id and a.deleted_at < ^cutoff,
          lock: "FOR UPDATE SKIP LOCKED"

      if Repo.exists?(claim), do: delete_account_data(account_id)
      {:ok, :ok}
    end)
  end

  defp delete_account_data(account_id) do
    member_ids = Repo.all(from m in Membership, where: m.account_id == ^account_id, select: m.user_id)

    for schema <- @purged_children do
      Repo.delete_all(from r in schema, where: r.account_id == ^account_id)
    end

    Repo.delete_all(from a in Account, where: a.id == ^account_id)
    delete_users_without_membership(member_ids)
  end

  defp delete_users_without_membership(user_ids) do
    orphans =
      from u in User,
        left_join: m in Membership,
        on: m.user_id == u.id,
        where: u.id in ^user_ids and is_nil(m.id),
        select: u.id

    orphan_ids = Repo.all(orphans)
    Repo.delete_all(from t in UserToken, where: t.user_id in ^orphan_ids)
    Repo.delete_all(from u in User, where: u.id in ^orphan_ids)
  end

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.shift(DateTime.utc_now(), minute: minutes))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  See `AssistantLink.Accounts.User.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  See `AssistantLink.Accounts.User.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """

  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.

  ## Examples

      iex> update_user_password(user, %{password: ...})
      {:ok, {%User{}, [...]}}

      iex> update_user_password(user, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Gets the user with the given magic link token.
  """
  def get_user_by_magic_link_token(token) do
    with {:ok, query} <- UserToken.verify_magic_link_token_query(token),
         {user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Logs the user in by magic link.

  There are three cases to consider:

  1. The user has already confirmed their email. They are logged in
     and the magic link is expired.

  2. The user has not confirmed their email and no password is set.
     In this case, the user gets confirmed, logged in, and all tokens -
     including session ones - are expired. In theory, no other tokens
     exist but we delete all of them for best security practices.

  3. The user has not confirmed their email but a password is set.
     This cannot happen in the default implementation but may be the
     source of security pitfalls. See the "Mixing magic link and password registration" section of
     `mix help phx.gen.auth`.
  """
  def login_user_by_magic_link(token) do
    {:ok, query} = UserToken.verify_magic_link_token_query(token)

    case Repo.one(query) do
      # Prevent session fixation attacks by disallowing magic links for unconfirmed users with password
      {%User{confirmed_at: nil, hashed_password: hash}, _token} when not is_nil(hash) ->
        raise """
        magic link log in is not allowed for unconfirmed users with a password set!

        This cannot happen with the default implementation, which indicates that you
        might have adapted the code to a different use case. Please make sure to read the
        "Mixing magic link and password registration" section of `mix help phx.gen.auth`.
        """

      {%User{confirmed_at: nil} = user, _token} ->
        user
        |> User.confirm_changeset()
        |> update_user_and_delete_all_tokens()

      {user, token} ->
        Repo.delete!(token)
        {:ok, {user, []}}

      nil ->
        {:error, :not_found}
    end
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/users/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Delivers the magic link login instructions to the given user.
  """
  def deliver_login_instructions(%User{} = user, magic_link_url_fun) when is_function(magic_link_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "login")
    Repo.insert!(user_token)
    UserNotifier.deliver_login_instructions(user, magic_link_url_fun.(encoded_token))
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end
end
