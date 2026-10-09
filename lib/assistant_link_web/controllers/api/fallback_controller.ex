defmodule AssistantLinkWeb.API.FallbackController do
  @moduledoc false
  use AssistantLinkWeb, :controller

  alias AssistantLinkWeb.APIError

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    APIError.send_error(conn, 422, "invalid_params", error_message(changeset))
  end

  def call(conn, {:error, :not_found}) do
    APIError.send_error(conn, 404, "not_found", "Not found.")
  end

  def call(conn, {:error, :already_paired}) do
    APIError.send_error(conn, 409, "already_paired", "This Assistant Link is already paired.")
  end

  def call(conn, {:error, :invalid_code}) do
    APIError.send_error(conn, 422, "invalid_code", "This pairing code is not valid. Ask the user for a new one.")
  end

  def call(conn, {:error, :expired_code}) do
    APIError.send_error(conn, 422, "expired_code", "This pairing code has expired. Ask the user for a new one.")
  end

  defp error_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&interpolate/1)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  defp interpolate({message, opts}) do
    Enum.reduce(opts, message, fn {key, value}, message ->
      String.replace(message, "%{#{key}}", fn _placeholder -> to_string(value) end)
    end)
  end
end
