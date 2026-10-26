defmodule AssistantLink.Links do
  @moduledoc false
  import Ecto.Query, warn: false

  alias AssistantLink.Accounts.Account
  alias AssistantLink.Accounts.Scope
  alias AssistantLink.Assistants
  alias AssistantLink.Events
  alias AssistantLink.Links.Link
  alias AssistantLink.Links.PairingCode
  alias AssistantLink.Presence
  alias AssistantLink.Repo
  alias AssistantLink.Tokens

  @pairing_code_ttl_minutes 15
  @pairing_code_attempts 3

  @doc """
  Creates an unpaired Link for one of the scope's Assistants. Returns `{:error, :not_found}` for an
  unknown id or another account's Assistant.
  """
  @spec create_link(Scope.t(), String.t(), map()) ::
          {:ok, Link.t()} | {:error, :not_found} | {:error, Ecto.Changeset.t()}
  def create_link(%Scope{} = scope, assistant_id, attrs) do
    case Assistants.get_assistant(scope, assistant_id) do
      nil ->
        {:error, :not_found}

      assistant ->
        Repo.transact(fn -> insert_link(assistant, attrs) end)
    end
  end

  defp insert_link(assistant, attrs) do
    changeset =
      Link.create_changeset(
        %Link{account_id: assistant.account_id, assistant_id: assistant.id, assistant: assistant},
        attrs
      )

    with {:ok, link} <- Repo.insert(changeset),
         {:ok, _event} <- Events.create_link_created(link),
         do: {:ok, link}
  end

  @doc """
  Issues a pairing code for one of the scope's unpaired Links, valid for 15 minutes. Any earlier code
  for the Link that was not used stops working. Returns the code formatted for display (`XXXX-XXXX`),
  its expiry, and the Link with its Assistant.

  Returns `{:error, :not_found}` for an unknown id or another account's Link, and
  `{:error, :already_paired}` for a paired Link.
  """
  @spec issue_pairing_code(Scope.t(), String.t()) ::
          {:ok, %{code: String.t(), expires_at: DateTime.t(), link: Link.t()}}
          | {:error, :not_found | :already_paired}
  def issue_pairing_code(%Scope{account: %{id: account_id}}, link_id) do
    case Ecto.UUID.cast(link_id) do
      {:ok, uuid} -> Repo.transact(fn -> issue_for_locked_link(account_id, uuid) end)
      :error -> {:error, :not_found}
    end
  end

  # The lock serializes concurrent requests for one Link, and pairing, so at most one unused code exists.
  defp issue_for_locked_link(account_id, id) do
    case Repo.one(from l in Link, where: l.id == ^id and l.account_id == ^account_id, lock: "FOR UPDATE") do
      %Link{paired_at: nil} = link -> replace_pairing_code(Repo.preload(link, :assistant))
      %Link{} -> {:error, :already_paired}
      nil -> {:error, :not_found}
    end
  end

  defp replace_pairing_code(link) do
    expires_at = DateTime.shift(DateTime.utc_now(), minute: @pairing_code_ttl_minutes)
    Repo.delete_all(from c in PairingCode, where: c.link_id == ^link.id and is_nil(c.used_at))
    code = insert_pairing_code(link, expires_at, @pairing_code_attempts)

    {:ok, %{code: Tokens.format_code(code), expires_at: expires_at, link: link}}
  end

  # Codes are only 8 characters, so a new one can match an earlier code; draw again when it does.
  defp insert_pairing_code(_link, _expires_at, 0), do: raise("no unused pairing code after retries")

  defp insert_pairing_code(link, expires_at, attempts_left) do
    code = Tokens.generate_code()

    row = %{
      id: Ecto.UUID.generate(version: 7, precision: :monotonic),
      account_id: link.account_id,
      link_id: link.id,
      code_hash: Tokens.hash(code),
      expires_at: expires_at,
      inserted_at: DateTime.utc_now()
    }

    case Repo.insert_all(PairingCode, [row], on_conflict: :nothing, conflict_target: :code_hash) do
      {1, _} -> code
      {0, _} -> insert_pairing_code(link, expires_at, attempts_left - 1)
    end
  end

  @doc """
  Pairs the Link a pairing code was issued for, however the code is typed: marks the code used and
  issues the Link's token. Returns the raw token, which is not retrievable later, and the Link with its
  Assistant.

  Returns `{:error, :invalid_code}` for an unknown, replaced, or used code or one of a deleted account, and
  `{:error, :expired_code}` for an unused code past its expiry.
  """
  @spec pair(String.t()) :: {:ok, %{link: Link.t(), token: String.t()}} | {:error, :invalid_code | :expired_code}
  def pair(code) when is_binary(code) do
    code_hash = code |> Tokens.normalize_code() |> Tokens.hash()

    lookup =
      from c in PairingCode,
        join: a in Account,
        on: a.id == c.account_id,
        where: c.code_hash == ^code_hash and is_nil(a.deleted_at),
        select: c.link_id

    case Repo.one(lookup) do
      nil -> {:error, :invalid_code}
      link_id -> Repo.transact(fn -> pair_locked_link(link_id, code_hash) end)
    end
  end

  # Locks the Link before reading its code again, in the same order as issue_for_locked_link/2, so a
  # code replaced or used meanwhile is seen as such. The account is checked again, as it may have been
  # deleted since the lookup.
  defp pair_locked_link(link_id, code_hash) do
    now = DateTime.utc_now()

    locked_link =
      from l in Link,
        join: a in Account,
        on: a.id == l.account_id,
        where: l.id == ^link_id and is_nil(a.deleted_at),
        lock: "FOR UPDATE",
        preload: :assistant

    with %Link{} = link <- Repo.one(locked_link),
         %PairingCode{used_at: nil} = code <- Repo.get_by(PairingCode, code_hash: code_hash, link_id: link_id) do
      if DateTime.after?(code.expires_at, now),
        do: pair_link(link, code, now),
        else: {:error, :expired_code}
    else
      _deleted_replaced_or_used -> {:error, :invalid_code}
    end
  end

  defp pair_link(link, pairing_code, now) do
    token = Tokens.generate(:link)
    Repo.update_all(from(c in PairingCode, where: c.id == ^pairing_code.id), set: [used_at: now])
    # The Assistant row is read without a lock: a message stored at this moment may or may not be delivered.
    changes = [token_hash: Tokens.hash(token), paired_at: now, last_read_seq: link.assistant.last_event_seq]
    link = link |> Ecto.Changeset.change(changes) |> Repo.update!()

    {:ok, %{link: link, token: token}}
  end

  @doc """
  Registers the calling process as an agent connection of a paired Link and records the Link as active
  now. The Link is online while any of its connection processes lives; call `disconnect/1` before the
  process exits to record when the connection closed.
  """
  @spec connect(Link.t()) :: :ok
  def connect(%Link{paired_at: %DateTime{}} = link) do
    {:ok, _ref} = Presence.track(self(), Presence.topic(link.account_id), link.id, %{active_at: record_activity(link)})
    :ok
  end

  @doc "Records that the calling process's agent connection of the Link is closing now."
  @spec disconnect(Link.t()) :: :ok
  def disconnect(%Link{} = link) do
    {:ok, _ref} = Presence.update(self(), Presence.topic(link.account_id), link.id, %{active_at: record_activity(link)})
    :ok
  end

  defp record_activity(%Link{id: id}) do
    now = DateTime.utc_now()
    Repo.update_all(from(l in Link, where: l.id == ^id), set: [last_active_at: now])
    now
  end

  @spec status(Link.t()) :: Link.status()
  def status(%Link{paired_at: nil}), do: :not_paired

  def status(%Link{id: id, account_id: account_id}),
    do: if(Presence.online?(account_id, id), do: :online, else: :offline)

  @doc """
  Returns the paired Link for a Link token, with its Assistant preloaded, or `nil` if no Link has it.
  A Link of a deleted account finds nothing.
  """
  @spec get_link_by_token(String.t()) :: Link.t() | nil
  def get_link_by_token(token) when is_binary(token) do
    Repo.one(
      from l in Link,
        join: a in assoc(l, :assistant),
        join: acc in Account,
        on: acc.id == l.account_id,
        where: l.token_hash == ^Tokens.hash(token) and is_nil(acc.deleted_at),
        preload: [assistant: a]
    )
  end
end
