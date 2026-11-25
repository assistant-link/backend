defmodule AssistantLinkWeb.API.TranscriptEntryController do
  use AssistantLinkWeb, :controller

  alias AssistantLink.Calls

  action_fallback AssistantLinkWeb.API.FallbackController

  def index(conn, %{"assistant_id" => assistant_id, "call_id" => call_id}) do
    with {:ok, entries} <- Calls.list_transcript(conn.assigns.current_scope, assistant_id, call_id) do
      render(conn, :index, transcript_entries: entries)
    end
  end

  def create(conn, %{"assistant_id" => assistant_id, "call_id" => call_id} = params) do
    with {:ok, entry, outcome} <-
           Calls.create_transcript_entry(conn.assigns.current_scope, assistant_id, call_id, params) do
      conn
      |> put_status(if outcome == :created, do: :created, else: :ok)
      |> render(:show, transcript_entry: entry)
    end
  end

  def update(conn, %{"assistant_id" => assistant_id, "call_id" => call_id, "id" => id} = params) do
    with {:ok, entry} <- Calls.update_transcript_entry(conn.assigns.current_scope, assistant_id, call_id, id, params) do
      render(conn, :show, transcript_entry: entry)
    end
  end
end
