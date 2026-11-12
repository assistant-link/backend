defmodule AssistantLinkWeb.WakeEmailConfirmationController do
  use AssistantLinkWeb, :controller

  alias AssistantLinkWeb.WakeEmail

  # Opening the link only shows a button, so a mail scanner that follows links confirms nothing.
  def show(conn, %{"token" => token}) do
    case WakeEmail.verify(token) do
      {:ok, link} -> render(conn, :show, address: link.wake_email, token: token)
      {:error, :invalid} -> conn |> put_status(400) |> render(:invalid)
    end
  end

  def create(conn, %{"token" => token}) do
    case WakeEmail.confirm(token) do
      {:ok, link} -> render(conn, :confirmed, address: link.wake_email)
      {:error, :invalid} -> conn |> put_status(400) |> render(:invalid)
    end
  end
end
