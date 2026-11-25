defmodule AssistantLinkWeb.API.CallJSON do
  alias AssistantLinkWeb.Endpoint

  def show(%{call: call}), do: %{call: call(call)}

  def call(call) do
    %{
      id: call.id,
      assistant_id: call.assistant_id,
      mode: call.mode,
      started_at: call.started_at,
      ended_at: call.ended_at,
      ended_by: call.ended_by
    }
  end

  @doc "The payload of the call's `voice_call` event."
  def voice_call(call) do
    %{
      call_id: call.id,
      mode: call.mode,
      started_at: call.started_at,
      ended_at: call.ended_at,
      duration_seconds: call.ended_at && DateTime.diff(call.ended_at, call.started_at),
      transcript_url: Endpoint.url() <> "/alp/v1/calls/#{call.id}/transcript"
    }
  end
end
