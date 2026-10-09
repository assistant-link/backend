defmodule AssistantLink.Assistants do
  @moduledoc false
  import Ecto.Query, warn: false

  alias AssistantLink.Accounts.Scope
  alias AssistantLink.Assistants.Assistant
  alias AssistantLink.Links.Link
  alias AssistantLink.Repo

  @doc "Lists the scope's Assistants, oldest first, each with its Links, oldest first."
  @spec list_assistants(Scope.t()) :: [Assistant.t()]
  def list_assistants(%Scope{account: %{id: account_id}}) do
    links = from l in Link, where: l.account_id == ^account_id, order_by: [asc: l.id]

    Repo.all(
      from a in Assistant,
        where: a.account_id == ^account_id,
        order_by: [asc: a.id],
        preload: [links: ^links]
    )
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
