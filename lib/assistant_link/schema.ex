defmodule AssistantLink.Schema do
  @moduledoc """
  Shared setup for this app's Ecto schemas: UUIDv7 primary and foreign keys, and timestamps in
  microseconds. Schemas whose rows are never updated declare `timestamps(updated_at: false)`.
  """

  import Ecto.Changeset

  defmacro __using__(_opts) do
    quote do
      use Ecto.Schema

      @primary_key {:id, Ecto.UUID, autogenerate: [version: 7, precision: :monotonic]}
      @foreign_key_type Ecto.UUID
      @timestamps_opts [type: :utc_datetime_usec]
    end
  end

  @doc """
  Validates that a text field is a single line: no control characters (such as line breaks or tabs) and
  no Unicode line or paragraph separators. Emoji and other printable text are allowed.
  """
  @spec validate_single_line(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_single_line(changeset, field) do
    validate_format(changeset, field, ~r/\A[^\p{Cc}\p{Zl}\p{Zp}]*\z/u,
      message: "must be a single line without control characters"
    )
  end
end
