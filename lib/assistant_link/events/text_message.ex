defmodule AssistantLink.Events.TextMessage do
  @moduledoc """
  The payload of a `text_message` event: 1 to 4,000 Unicode code points, not only White_Space, and no U+0000.
  """
  use AssistantLink.Schema

  @primary_key {:event_id, Ecto.UUID, autogenerate: false}

  @max_length 4000

  @type t :: %__MODULE__{}

  schema "text_messages" do
    field :text, :string

    belongs_to :account, AssistantLink.Accounts.Account
  end

  @spec validate_text(term()) :: :ok | {:error, :text_empty | :text_too_long | :invalid_params}
  def validate_text(text) when is_binary(text) do
    cond do
      String.trim(text) == "" -> {:error, :text_empty}
      length(String.to_charlist(text)) > @max_length -> {:error, :text_too_long}
      String.contains?(text, <<0>>) -> {:error, :invalid_params}
      true -> :ok
    end
  end

  def validate_text(_text), do: {:error, :invalid_params}
end
