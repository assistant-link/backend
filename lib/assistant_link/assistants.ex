defmodule AssistantLink.Assistants do
  @moduledoc false
  import Ecto.Query, warn: false

  alias AssistantLink.Accounts.Scope
  alias AssistantLink.Assistants.Assistant
  alias AssistantLink.Events.Event
  alias AssistantLink.Links.Link
  alias AssistantLink.Repo

  @doc """
  Lists the scope's Assistants, oldest first, each with its Links, oldest first, and its latest event
  (`latest_event`, `nil` while it has none).
  """
  @spec list_assistants(Scope.t()) :: [Assistant.t()]
  def list_assistants(%Scope{account: %{id: account_id}}) do
    links = from l in Link, where: l.account_id == ^account_id, order_by: [asc: l.id]

    latest_events =
      Map.new(
        Repo.all(
          from e in Event,
            join: a in Assistant,
            on: a.id == e.assistant_id and a.last_event_seq == e.seq,
            where: a.account_id == ^account_id,
            preload: :text_message
        ),
        &{&1.assistant_id, &1}
      )

    from(a in Assistant,
      where: a.account_id == ^account_id,
      order_by: [asc: a.id],
      preload: [links: ^links]
    )
    |> Repo.all()
    |> Enum.map(&%{&1 | latest_event: latest_events[&1.id]})
  end

  @doc "Gets one of the scope's Assistants. Returns `nil` for an unknown id or another account's Assistant."
  @spec get_assistant(Scope.t(), String.t()) :: Assistant.t() | nil
  def get_assistant(%Scope{account: %{id: account_id}}, id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get_by(Assistant, id: uuid, account_id: account_id)
      :error -> nil
    end
  end

  @spec create_assistant(Scope.t(), map()) :: {:ok, Assistant.t()} | {:error, Ecto.Changeset.t()}
  def create_assistant(%Scope{account: %{id: account_id}}, attrs) do
    %Assistant{account_id: account_id, links: []}
    |> Assistant.create_changeset(attrs)
    |> Repo.insert()
  end
end
