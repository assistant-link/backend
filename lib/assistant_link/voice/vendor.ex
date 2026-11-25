defmodule AssistantLink.Voice.Vendor do
  @moduledoc """
  A realtime voice model behind a call. The vendor is a process linked to the call's
  `AssistantLink.Voice.Session`, started with:

    * `:session` - the session pid, which gets the vendor's messages
    * `:call` - the `AssistantLink.Calls.Call`
    * `:assistant` - the `AssistantLink.Assistants.Assistant` the voice speaks as
    * `:instructions` - the voice agent's system prompt

  It hears the user through `send_audio/2` with the Opus RTP packets the app sends, and sends the session:

    * `{:voice_vendor, vendor, {:audio, packet}}` with an Opus RTP packet to play to the user
    * `{:voice_vendor, vendor, {:transcript, speaker, text, started_at, ended_at}}` with the next part of what
      the `:user` or the `:assistant` said, and when that part was spoken

  `start_link/1` returns only once the vendor is ready, and `{:error, :voice_unavailable}` when it cannot start.
  The session stops when the vendor exits.
  """

  @type speaker() :: :user | :assistant

  @callback start_link(keyword()) :: {:ok, pid()} | {:error, :voice_unavailable}
  @callback send_audio(pid(), ExRTP.Packet.t()) :: :ok
  @doc "Ends the vendor session gracefully and stops the process."
  @callback close(pid()) :: :ok
end
