defmodule AssistantLink.Events do
  @moduledoc """
  An Assistant's Timeline: its events, in order of `seq`.

  Subscribers to the account (see `AssistantLink.Accounts.subscribe/1`) get `{:event_created, event}`
  for each stored text message and `{:event_updated, event}` when a user message is first delivered.
  """
  import Ecto.Query, warn: false

  alias AssistantLink.Accounts
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
  def create_text_message(%Scope{account: %{id: account_id}} = scope, assistant_id, params) do
    case Assistants.get_assistant(scope, assistant_id) do
      %Assistant{} = assistant ->
        case stored(account_id, params["idempotency_key"]) do
          %Event{} = event -> replay(event, assistant, params["text"])
          nil -> store_text_message(scope, assistant, params)
        end

      nil ->
        {:error, :not_found}
    end
  end

  # Ecto.UUID.cast/1 also takes a raw 16-byte binary; a key is only the 36-character text form.
  defp stored(account_id, <<_::288>> = key) do
    case Ecto.UUID.cast(key) do
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

  defp stored(_account_id, _key), do: nil

  # A deleted payload has no text to differ from.
  defp replay(%Event{assistant_id: assistant_id, text_message: stored_text} = event, %Assistant{id: assistant_id}, text)
       when is_nil(stored_text) or stored_text.text == text, do: {:ok, event, :existing}

  defp replay(_event, _assistant, _text), do: {:error, :idempotency_key_conflict}

  defp store_text_message(scope, assistant, params) do
    text = params["text"]

    with :ok <- TextMessage.validate_text(text),
         {:ok, key} <- cast_uuid_v7(params["idempotency_key"]),
         {:ok, event} <- Repo.transact(fn -> insert_text_message(assistant, text, key) end) do
      broadcast(event.account_id, {:event_created, event})
      {:ok, event, :created}
    else
      # A concurrent request stored the key first; its event is the answer.
      {:error, :key_taken} -> create_text_message(scope, assistant.id, params)
      {:error, _reason} = error -> error
    end
  end

  defp cast_uuid_v7(<<_::288>> = key) do
    with {:ok, uuid} <- Ecto.UUID.cast(key),
         {:ok, <<_::48, 7::4, _::12, 2::2, _::62>>} <- Ecto.UUID.dump(uuid) do
      {:ok, uuid}
    else
      _not_uuid_v7 -> {:error, :invalid_params}
    end
  end

  defp cast_uuid_v7(_key), do: {:error, :invalid_params}

  defp insert_text_message(assistant, text, key) do
    event = %Event{
      account_id: assistant.account_id,
      assistant_id: assistant.id,
      type: :text_message,
      sender: :user,
      idempotency_key: key
    }

    with {:paired, true} <-
           {:paired, Repo.exists?(from l in Link, where: l.assistant_id == ^assistant.id and not is_nil(l.paired_at))},
         {:ok, event} <- insert_event(event) do
      payload = Repo.insert!(%TextMessage{event_id: event.id, account_id: event.account_id, text: text})
      {:ok, %{event | text_message: payload}}
    else
      {:paired, false} -> {:error, :no_paired_link}
      {:error, _changeset} -> {:error, :key_taken}
    end
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
  Sets `delivered_at` of a user's text message of the account the first time only, and sends
  `{:event_updated, event}` to the account's subscribers. Otherwise does nothing.
  """
  @spec mark_delivered(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok
  def mark_delivered(account_id, event_id) do
    undelivered =
      from e in Event,
        where:
          e.id == ^event_id and e.account_id == ^account_id and e.type == :text_message and e.sender == :user and
            is_nil(e.delivered_at),
        select: e

    case Repo.update_all(undelivered, set: [delivered_at: DateTime.utc_now()]) do
      {1, [event]} -> broadcast(account_id, {:event_updated, Repo.preload(event, :text_message)})
      {0, []} -> :ok
    end
  end

  defp broadcast(account_id, message),
    do: Phoenix.PubSub.broadcast(AssistantLink.PubSub, Accounts.topic(account_id), message)
end
