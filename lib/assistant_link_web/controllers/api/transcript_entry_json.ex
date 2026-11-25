defmodule AssistantLinkWeb.API.TranscriptEntryJSON do
  def index(%{transcript_entries: entries}), do: %{transcript_entries: Enum.map(entries, &transcript_entry/1)}

  def show(%{transcript_entry: entry}), do: %{transcript_entry: transcript_entry(entry)}

  def transcript_entry(entry) do
    %{
      id: entry.id,
      call_id: entry.call_id,
      seq: entry.seq,
      speaker: entry.speaker,
      text: entry.text,
      started_at: entry.started_at,
      ended_at: entry.ended_at
    }
  end
end
