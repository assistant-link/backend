defmodule AssistantLink.Events do
  @moduledoc """
  An Assistant's Timeline: its events, in order of `seq`.

  Subscribers to the account (see `AssistantLink.Accounts.subscribe/1`) get `{:event_created, event}`
  for each stored text message and `{:event_updated, event}` when a user message is first delivered.
  """
  import Ecto.Query, warn: false

  alias AssistantLink.Accounts
  alias AssistantLink.Accounts.Account
  alias AssistantLink.Accounts.Scope
  alias AssistantLink.Assistants
  alias AssistantLink.Assistants.Assistant
  alias AssistantLink.Events.Event
  alias AssistantLink.Events.TextMessage
  alias AssistantLink.Links.Link
  alias AssistantLink.Repo

  @default_limit 50
  @max_limit 100

  @doc "Stores the `link_created` event of a new Link. Call it in the transaction that creates the Link."
  @spec create_link_created(Link.t()) :: {:ok, Event.t()} | {:error, Ecto.Changeset.t()}
  def create_link_created(%Link{} = link) do
    insert_event(%Event{
      account_id: link.account_id,
      assistant_id: link.assistant_id,
      link_id: link.id,
      type: :link_created,
      sender: :system
    })
  end

  @doc """
  Lists an Assistant's events, oldest first, with whether older ones exist. Params are `"limit"`
  (1 to 100, default 50) and `"before"`, the id of an event of the Assistant to list the ones before.
  """
  @spec list_events(Scope.t(), String.t(), map()) ::
          {:ok, %{events: [Event.t()], has_more: boolean()}} | {:error, :not_found | :invalid_params}
  def list_events(%Scope{} = scope, assistant_id, params) do
    with %Assistant{} = assistant <- Assistants.get_assistant(scope, assistant_id),
         {:ok, limit} <- parse_limit(params["limit"]),
         {:ok, before_seq} <- before_seq(assistant, params["before"]) do
      query =
        from e in Event,
          where: e.assistant_id == ^assistant.id and e.seq < ^before_seq,
          order_by: [desc: e.seq],
          limit: ^(limit + 1),
          preload: :text_message

      {page, older} = query |> Repo.all() |> Enum.split(limit)
      {:ok, %{events: Enum.reverse(page), has_more: older != []}}
    else
      nil -> {:error, :not_found}
      {:error, :invalid_params} = error -> error
    end
  end

  defp parse_limit(nil), do: {:ok, @default_limit}

  defp parse_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {limit, ""} when limit in 1..@max_limit -> {:ok, limit}
      _invalid -> {:error, :invalid_params}
    end
  end

  defp parse_limit(_limit), do: {:error, :invalid_params}

  defp before_seq(assistant, nil), do: {:ok, assistant.last_event_seq + 1}

  defp before_seq(assistant, id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         seq when is_integer(seq) <-
           Repo.one(from e in Event, where: e.id == ^uuid and e.assistant_id == ^assistant.id, select: e.seq) do
      {:ok, seq}
    else
      _unknown -> {:error, :invalid_params}
    end
  end

  @doc """
  Stores a user's text message to one of the scope's Assistants. Params are `"text"` and
  `"idempotency_key"` (a UUIDv7).

  A stored key returns its event as `{:ok, event, :existing}`, or `{:error, :idempotency_key_conflict}`
  when the text or the Assistant differs. Checks run in this order: Assistant, stored key, text and
  params, paired Link.
  """
  @spec create_text_message(Scope.t(), String.t(), map()) ::
          {:ok, Event.t(), :created | :existing}
          | {:error,
             :not_found
             | :idempotency_key_conflict
             | :text_empty
             | :text_too_long
             | :invalid_params
             | :no_paired_link}
  def create_text_message(%Scope{} = scope, assistant_id, params) do
    case Assistants.get_assistant(scope, assistant_id) do
      %Assistant{} = assistant ->
        store(%Event{account_id: assistant.account_id, assistant_id: assistant.id, sender: :user}, params)

      nil ->
        {:error, :not_found}
    end
  end

  @doc """
  Stores an agent's text message as its Link's Assistant. Params are `"text"` and an optional
  `"idempotency_key"` (a UUIDv7) that only the same Link and text can repeat. Otherwise it works like
  `create_text_message/3`, without the paired Link check.
  """
  @spec create_assistant_message(Link.t(), map()) ::
          {:ok, Event.t(), :created | :existing}
          | {:error, :idempotency_key_conflict | :text_empty | :text_too_long | :invalid_params}
  def create_assistant_message(%Link{} = link, params) do
    store(
      %Event{account_id: link.account_id, assistant_id: link.assistant_id, link_id: link.id, sender: :assistant},
      params
    )
  end

  # The event's sender, Assistant and Link are the message's identity for a repeated key.
  defp store(%Event{} = template, params) do
    case stored(template.account_id, params["idempotency_key"]) do
      %Event{} = event -> replay(event, template, params["text"])
      nil -> store_text_message(template, params)
    end
  end

  defp stored(account_id, key) do
    case cast_text_uuid(key) do
      {:ok, uuid} ->
        Repo.one(
          from e in Event,
            where: e.account_id == ^account_id and e.idempotency_key == ^uuid,
            preload: :text_message
        )

      :error ->
        nil
    end
  end

  # Ecto.UUID.cast/1 also takes a raw 16-byte binary; an id from a client is only the 36-character text form.
  defp cast_text_uuid(<<_::288>> = id), do: Ecto.UUID.cast(id)
  defp cast_text_uuid(_id), do: :error

  # A deleted payload has no text to differ from.
  defp replay(%Event{text_message: stored_text} = event, template, text) do
    if (is_nil(stored_text) or stored_text.text == text) and identity(event) == identity(template),
      do: {:ok, event, :existing},
      else: {:error, :idempotency_key_conflict}
  end

  defp identity(event), do: {event.assistant_id, event.sender, event.link_id}

  defp store_text_message(template, params) do
    text = params["text"]

    with :ok <- TextMessage.validate_text(text),
         {:ok, key} <- cast_key(template, params["idempotency_key"]),
         {:ok, event} <- Repo.transact(fn -> insert_text_message(template, text, key) end) do
      broadcast(event.account_id, {:event_created, event})
      {:ok, event, :created}
    else
      # A concurrent request stored the key first; its event is the answer.
      {:error, :key_taken} -> store(template, params)
      {:error, _reason} = error -> error
    end
  end

  defp cast_key(%Event{sender: :assistant}, nil), do: {:ok, nil}

  defp cast_key(_template, key) do
    with {:ok, uuid} <- cast_text_uuid(key),
         {:ok, <<_::48, 7::4, _::12, 2::2, _::62>>} <- Ecto.UUID.dump(uuid) do
      {:ok, uuid}
    else
      _not_uuid_v7 -> {:error, :invalid_params}
    end
  end

  defp insert_text_message(template, text, key) do
    with :ok <- check_paired(template),
         {:ok, event} <- insert_event(%{template | type: :text_message, idempotency_key: key}) do
      payload = Repo.insert!(%TextMessage{event_id: event.id, account_id: event.account_id, text: text})
      {:ok, %{event | text_message: payload}}
    else
      {:error, :no_paired_link} = error -> error
      {:error, _changeset} -> {:error, :key_taken}
    end
  end

  defp check_paired(%Event{sender: :assistant}), do: :ok

  defp check_paired(%Event{assistant_id: assistant_id}) do
    if Repo.exists?(from l in Link, where: l.assistant_id == ^assistant_id and not is_nil(l.paired_at)),
      do: :ok,
      else: {:error, :no_paired_link}
  end

  # Taking the next seq locks the Assistant's row until the transaction ends, so seqs are gapless.
  defp insert_event(%Event{account_id: account_id, assistant_id: assistant_id} = event) do
    {1, [seq]} =
      Repo.update_all(
        from(a in Assistant,
          where: a.id == ^assistant_id and a.account_id == ^account_id,
          select: a.last_event_seq,
          update: [inc: [last_event_seq: 1]]
        ),
        []
      )

    event
    |> Ecto.Changeset.change(seq: seq)
    |> Ecto.Changeset.unique_constraint(:idempotency_key, name: :assistant_events_account_id_idempotency_key_index)
    |> Repo.insert()
  end

  @doc """
  The next event to deliver to a Link: the user's text message with the lowest `seq` after the Link's
  cursor, a deleted one included. `nil` when there is none or the account was deleted.
  """
  @spec next_deliverable(Ecto.UUID.t()) :: Event.t() | nil
  def next_deliverable(link_id) do
    link_id |> deliverable() |> order_by(asc: :seq) |> limit(1) |> preload(:text_message) |> Repo.one()
  end

  @doc "The number of events after the Link's cursor that `next_deliverable/1` would return in turn."
  @spec count_deliverable(Ecto.UUID.t()) :: non_neg_integer()
  def count_deliverable(link_id), do: link_id |> deliverable() |> Repo.aggregate(:count)

  defp user_messages, do: from(e in Event, where: e.type == :text_message and e.sender == :user)

  defp deliverable(link_id) do
    from e in user_messages(),
      join: l in Link,
      on: l.assistant_id == e.assistant_id and l.account_id == e.account_id,
      join: a in Account,
      on: a.id == e.account_id,
      where: l.id == ^link_id and is_nil(a.deleted_at) and e.seq > l.last_read_seq
  end

  @doc """
  Moves the Link's cursor to the event a Link acknowledged and, for the first acknowledgement by any
  Link, calls `mark_delivered/2`. An `event_id` that is not a user's text message of the Link's
  Assistant after its cursor changes nothing, so the cursor never moves backward.
  """
  @spec acknowledge(Ecto.UUID.t(), term()) :: :ok
  def acknowledge(link_id, event_id) do
    with {:ok, uuid} <- cast_text_uuid(event_id),
         {1, [account_id]} <- advance_cursor(link_id, uuid) do
      mark_delivered(account_id, uuid)
    else
      _unusable -> :ok
    end
  end

  defp advance_cursor(link_id, event_id) do
    advance =
      from l in Link,
        join: e in ^user_messages(),
        on: e.assistant_id == l.assistant_id and e.account_id == l.account_id,
        join: a in Account,
        on: a.id == l.account_id,
        where: l.id == ^link_id and e.id == ^event_id and e.seq > l.last_read_seq and is_nil(a.deleted_at),
        select: l.account_id,
        update: [set: [last_read_seq: e.seq]]

    Repo.update_all(advance, [])
  end

  @doc """
  Sets `delivered_at` of a user's text message of the account the first time only, and sends
  `{:event_updated, event}` to the account's subscribers. Otherwise does nothing.
  """
  @spec mark_delivered(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok
  def mark_delivered(account_id, event_id) do
    undelivered =
      from e in user_messages(),
        join: a in Account,
        on: a.id == e.account_id,
        where: e.id == ^event_id and e.account_id == ^account_id and is_nil(e.delivered_at) and is_nil(a.deleted_at),
        select: e

    case Repo.update_all(undelivered, set: [delivered_at: DateTime.utc_now()]) do
      {1, [event]} -> broadcast(account_id, {:event_updated, Repo.preload(event, :text_message)})
      {0, []} -> :ok
    end
  end

  defp broadcast(account_id, message),
    do: Phoenix.PubSub.broadcast(AssistantLink.PubSub, Accounts.topic(account_id), message)
end
