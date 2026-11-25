defmodule AssistantLink.Calls do
  @moduledoc """
  Voice calls and their transcripts. A call shows in its Assistant's Timeline as one `voice_call` event, sent
  as `{:event_created, event}` when the call starts and `{:event_updated, event}` when it ends. Starting and
  ending a call also store the `call_started` and `call_ended` events that agents and older apps follow.

  Subscribers to the account get `{:call_transcript_entry, entry}` each time an entry is saved or updated.
  """
  import Ecto.Query, warn: false

  alias AssistantLink.Accounts
  alias AssistantLink.Accounts.Scope
  alias AssistantLink.Assistants
  alias AssistantLink.Assistants.Assistant
  alias AssistantLink.Calls.Call
  alias AssistantLink.Calls.TranscriptEntry
  alias AssistantLink.Events
  alias AssistantLink.Events.Event
  alias AssistantLink.Repo
  alias Ecto.Changeset

  # An open call that started longer ago than this counts as one whose end never arrived.
  @call_window_minutes 60

  @doc """
  Starts a call with one of the scope's Assistants. Params are an optional `"mode"`, `"realtime_relay"`
  (the default) or `"native"`. Returns the new call with its `call_started` event. An open call from the last
  #{@call_window_minutes} minutes is returned as `{:ok, call, :existing}`, so a repeated request gets the call it
  started; an older one is ended as the system's first.
  """
  @spec start_call(Scope.t(), String.t(), map()) ::
          {:ok, Call.t(), Event.t() | :existing} | {:error, :not_found | :invalid_params}
  def start_call(%Scope{} = scope, assistant_id, params) do
    with %Assistant{} = assistant <- Assistants.get_assistant(scope, assistant_id),
         {:ok, mode} <- cast_mode(params["mode"]),
         {:ok, {call, started, notices}} <- Repo.transact(fn -> insert_call(assistant, mode) end) do
      broadcast(assistant.account_id, notices)
      {:ok, call, started}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp cast_mode(nil), do: {:ok, :realtime_relay}
  defp cast_mode("realtime_relay"), do: {:ok, :realtime_relay}
  defp cast_mode("native"), do: {:ok, :native}
  defp cast_mode(_mode), do: {:error, :invalid_params}

  defp insert_call(assistant, mode) do
    lock_assistant(assistant.id)

    call = open_call(assistant.id)

    if current?(call) do
      {:ok, {call, :existing, []}}
    else
      {:ok, ended} = end_open_call(assistant.id, :system)
      template = %Event{account_id: assistant.account_id, assistant_id: assistant.id, sender: :user}

      with {:ok, voice_call} <- insert_voice_call(assistant.account_id, assistant.id, mode),
           {:ok, started} <- Events.insert_event(%{template | type: :call_started}) do
        {:ok, {voice_call.call, started, ended ++ [{:event_created, voice_call}, {:event_created, started}]}}
      end
    end
  end

  @doc """
  Ends one of the scope's calls as the user's and stores the user's `call_ended`. A call of another Assistant
  is `{:error, :call_not_found}`, an ended one `{:error, :call_already_ended}`.
  """
  @spec end_call(Scope.t(), String.t(), String.t()) ::
          {:ok, Call.t()} | {:error, :not_found | :call_not_found | :call_already_ended}
  def end_call(%Scope{} = scope, assistant_id, id) do
    with %Assistant{} = assistant <- Assistants.get_assistant(scope, assistant_id),
         {:ok, {call, notices}} <- Repo.transact(fn -> end_user_call(assistant, id) end) do
      broadcast(assistant.account_id, notices)
      {:ok, call}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp end_user_call(assistant, id) do
    lock_assistant(assistant.id)

    case get_assistant_call(assistant, id) do
      %Call{ended_at: nil} = call ->
        voice_call = close(call, :user)
        template = %Event{account_id: assistant.account_id, assistant_id: assistant.id, sender: :user}

        with {:ok, ended} <- Events.insert_event(%{template | type: :call_ended}) do
          {:ok, {voice_call.call, [{:event_updated, voice_call}, {:event_created, ended}]}}
        end

      %Call{} ->
        {:error, :call_already_ended}

      nil ->
        {:error, :call_not_found}
    end
  end

  @doc "Gets a call of one of the scope's Assistants."
  @spec get_call(Scope.t(), String.t(), String.t()) :: {:ok, Call.t()} | {:error, :not_found | :call_not_found}
  def get_call(%Scope{} = scope, assistant_id, id) do
    case Assistants.get_assistant(scope, assistant_id) do
      %Assistant{} = assistant ->
        if call = get_assistant_call(assistant, id), do: {:ok, call}, else: {:error, :call_not_found}

      nil ->
        {:error, :not_found}
    end
  end

  defp get_assistant_call(assistant, id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get_by(Call, id: uuid, assistant_id: assistant.id, account_id: assistant.account_id)
      :error -> nil
    end
  end

  @doc "Lists a call's transcript entries in order of `seq`."
  @spec list_transcript(Scope.t(), String.t(), String.t()) ::
          {:ok, [TranscriptEntry.t()]} | {:error, :not_found | :call_not_found}
  def list_transcript(%Scope{} = scope, assistant_id, call_id) do
    with {:ok, call} <- get_call(scope, assistant_id, call_id) do
      {:ok, Repo.all(from t in TranscriptEntry, where: t.call_id == ^call.id, order_by: t.seq)}
    end
  end

  @doc """
  Saves a transcript entry with the call's next `seq`, also after the call ended. Params are `"speaker"`
  (`"user"` or `"assistant"`), `"text"`, `"started_at"`, an optional `"ended_at"`, and an optional `"id"`
  (a UUIDv7) so a repeated request returns the saved entry as `{:ok, entry, :existing}`.
  """
  @spec create_transcript_entry(Scope.t(), String.t(), String.t(), map()) ::
          {:ok, TranscriptEntry.t(), :created | :existing}
          | {:error, :not_found | :call_not_found | :invalid_params | Changeset.t()}
  def create_transcript_entry(%Scope{} = scope, assistant_id, call_id, params) do
    with {:ok, call} <- get_call(scope, assistant_id, call_id),
         {:ok, id} <- cast_entry_id(params["id"]) do
      case id && Repo.get_by(TranscriptEntry, id: id, call_id: call.id) do
        %TranscriptEntry{} = entry -> {:ok, entry, :existing}
        nil -> insert_entry(call, id, params)
      end
    end
  end

  defp cast_entry_id(nil), do: {:ok, nil}

  defp cast_entry_id(<<_::288>> = id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         {:ok, <<_::48, 7::4, _::12, 2::2, _::62>>} <- Ecto.UUID.dump(uuid) do
      {:ok, uuid}
    else
      _not_uuid_v7 -> {:error, :invalid_params}
    end
  end

  defp cast_entry_id(_id), do: {:error, :invalid_params}

  defp insert_entry(call, id, params) do
    changeset = TranscriptEntry.create_changeset(%TranscriptEntry{id: id, account_id: call.account_id}, params)

    result =
      Repo.transact(fn ->
        Repo.one!(from c in Call, where: c.id == ^call.id, lock: "FOR UPDATE", select: c.id)
        seq = Repo.one(from t in TranscriptEntry, where: t.call_id == ^call.id, select: max(t.seq)) || 0

        changeset
        |> Changeset.put_change(:call_id, call.id)
        |> Changeset.put_change(:seq, seq + 1)
        |> Changeset.unique_constraint(:id, name: :call_transcript_entries_pkey)
        |> Repo.insert()
      end)

    case result do
      {:ok, entry} ->
        broadcast(call.account_id, [{:call_transcript_entry, entry}])
        {:ok, entry, :created}

      {:error, %Changeset{errors: [id: _taken]}} ->
        {:error, :invalid_params}

      {:error, _changeset} = error ->
        error
    end
  end

  @doc ~s(Updates the `"text"` and `"ended_at"` of a call's transcript entry, also after the call ended.)
  @spec update_transcript_entry(Scope.t(), String.t(), String.t(), String.t(), map()) ::
          {:ok, TranscriptEntry.t()} | {:error, :not_found | :call_not_found | Changeset.t()}
  def update_transcript_entry(%Scope{} = scope, assistant_id, call_id, id, params) do
    with {:ok, call} <- get_call(scope, assistant_id, call_id),
         {:ok, uuid} <- Ecto.UUID.cast(id),
         %TranscriptEntry{} = entry <- Repo.get_by(TranscriptEntry, id: uuid, call_id: call.id),
         {:ok, entry} <- entry |> TranscriptEntry.update_changeset(params) |> Repo.update() do
      broadcast(call.account_id, [{:call_transcript_entry, entry}])
      {:ok, entry}
    else
      {:error, %Changeset{}} = error -> error
      {:error, :call_not_found} = error -> error
      {:error, :not_found} = error -> error
      _unknown_entry -> {:error, :not_found}
    end
  end

  @doc "Whether the Assistant has an open call that started in the last #{@call_window_minutes} minutes."
  @spec on_call?(Ecto.UUID.t()) :: boolean()
  def on_call?(assistant_id), do: assistant_id |> open_call() |> current?()

  @doc "Locks the Assistant's row until the transaction ends, so its calls open and end one at a time."
  @spec lock_assistant(Ecto.UUID.t()) :: Ecto.UUID.t()
  def lock_assistant(assistant_id),
    do: Repo.one!(from a in Assistant, where: a.id == ^assistant_id, lock: "FOR UPDATE", select: a.id)

  @doc """
  Opens a call and stores its `voice_call` event, which it returns with the call. Run it in a transaction that
  holds `lock_assistant/1`, after `end_open_call/2`.
  """
  @spec insert_voice_call(Ecto.UUID.t(), Ecto.UUID.t(), atom()) :: {:ok, Event.t()} | {:error, Changeset.t()}
  def insert_voice_call(account_id, assistant_id, mode) do
    event = %Event{account_id: account_id, assistant_id: assistant_id, sender: :system, type: :voice_call}

    with {:ok, event} <- Events.insert_event(event) do
      call =
        Repo.insert!(%Call{
          account_id: account_id,
          assistant_id: assistant_id,
          event_id: event.id,
          mode: mode,
          started_at: event.inserted_at
        })

      {:ok, %{event | call: call}}
    end
  end

  @doc """
  Ends the Assistant's open call, if any, and returns the notice of its updated `voice_call` to send once the
  transaction commits. Run it in a transaction that holds `lock_assistant/1`.
  """
  @spec end_open_call(Ecto.UUID.t(), :user | :assistant | :system) :: {:ok, [{:event_updated, Event.t()}]}
  def end_open_call(assistant_id, ended_by) do
    case open_call(assistant_id) do
      %Call{} = call -> {:ok, [{:event_updated, close(call, ended_by)}]}
      nil -> {:ok, []}
    end
  end

  defp open_call(assistant_id),
    do: Repo.one(from c in Call, where: c.assistant_id == ^assistant_id and is_nil(c.ended_at))

  defp current?(%Call{started_at: started_at}),
    do: DateTime.after?(started_at, DateTime.shift(DateTime.utc_now(), minute: -@call_window_minutes))

  defp current?(nil), do: false

  defp close(call, ended_by) do
    call = call |> Changeset.change(ended_at: DateTime.utc_now(), ended_by: ended_by) |> Repo.update!()
    %{Repo.get!(Event, call.event_id) | call: call}
  end

  defp broadcast(account_id, notices) do
    for notice <- notices, do: Phoenix.PubSub.broadcast(AssistantLink.PubSub, Accounts.topic(account_id), notice)
    :ok
  end
end
