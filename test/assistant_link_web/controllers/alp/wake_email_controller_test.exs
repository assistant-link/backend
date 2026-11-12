defmodule AssistantLinkWeb.ALP.WakeEmailControllerTest do
  use AssistantLinkWeb.ConnCase, async: true

  import AssistantLink.LinksFixtures

  alias AssistantLink.Links
  alias AssistantLink.Repo
  alias AssistantLinkWeb.WakeEmail

  setup :register_device

  setup %{conn: conn, scope: scope} do
    {link, token} = paired_link_fixture(scope)
    %{conn: put_req_header(conn, "authorization", "Bearer " <> token), link: link}
  end

  defp put_address(conn, address) do
    conn |> put(~p"/alp/v1/link/wake_email", %{"address" => address}) |> json_response(200)
  end

  defp confirmation_path do
    assert_receive {:email, email}, 1000
    [path] = Regex.run(~r{/wake-email/confirm/[^\s]+}, email.text_body)
    {email, path}
  end

  test "setting an address sends a confirmation and does not enable wakes", %{conn: conn, link: link} do
    assert put_address(conn, "hermes@example.com") ==
             %{"wake_email" => %{"address" => "hermes@example.com", "confirmed" => false}}

    {email, path} = confirmation_path()
    assert email.to == [{"", "hermes@example.com"}]
    assert email.from == {"Assistant Link", "no-reply@mail.assistantlink.ai"}
    assert email.subject =~ "Confirm"
    assert email.text_body =~ "Hermes"
    assert email.text_body =~ "24 hours"
    assert email.text_body =~ "Do not reply to this email"
    assert email.text_body =~ "curl -X POST"
    assert path =~ "/wake-email/confirm/"

    assert Links.status(Repo.reload!(link)) == :offline
    refute_receive {:email, _email}
  end

  test "opening the link shows a button, and pressing it confirms the address", %{conn: conn, link: link} do
    put_address(conn, "hermes@example.com")
    {_email, path} = confirmation_path()

    page = build_conn() |> get(path) |> html_response(200)
    assert page =~ "id=\"wake-email-confirm-form\""
    assert page =~ "hermes@example.com"
    refute Links.show_wake_email(Repo.reload!(link)).confirmed

    assert build_conn() |> post(path) |> html_response(200) =~ "id=\"wake-email-confirmed\""
    assert Links.show_wake_email(Repo.reload!(link)).confirmed
    assert Links.status(Repo.reload!(link)) == :idle

    assert conn |> get(~p"/alp/v1/link/wake_email") |> json_response(200) ==
             %{"wake_email" => %{"address" => "hermes@example.com", "confirmed" => true}}

    assert build_conn() |> post(path) |> html_response(200) =~ "id=\"wake-email-confirmed\""
  end

  test "setting the confirmed address again sends nothing and keeps it confirmed", %{conn: conn} do
    put_address(conn, "hermes@example.com")
    {_email, path} = confirmation_path()
    build_conn() |> post(path) |> html_response(200)

    assert put_address(conn, "hermes@example.com")["wake_email"]["confirmed"]
    refute_receive {:email, _email}
  end

  test "setting an unconfirmed address again sends another confirmation", %{conn: conn} do
    put_address(conn, "hermes@example.com")
    confirmation_path()

    put_address(conn, "hermes@example.com")
    assert {%{to: [{"", "hermes@example.com"}]}, _path} = confirmation_path()
  end

  test "a link for an address that was replaced or cleared confirms nothing", %{conn: conn, link: link} do
    put_address(conn, "old@example.com")
    {_email, old_path} = confirmation_path()
    put_address(conn, "new@example.com")
    {_email, new_path} = confirmation_path()

    assert build_conn() |> get(old_path) |> html_response(400) =~ "id=\"wake-email-invalid\""
    assert build_conn() |> post(old_path) |> html_response(400) =~ "id=\"wake-email-invalid\""
    refute Links.show_wake_email(Repo.reload!(link)).confirmed

    assert conn |> delete(~p"/alp/v1/link/wake_email") |> response(204)
    assert build_conn() |> post(new_path) |> html_response(400) =~ "id=\"wake-email-invalid\""
    assert Links.show_wake_email(Repo.reload!(link)) == nil
  end

  test "an expired or forged link confirms nothing", %{conn: conn, link: link} do
    put_address(conn, "hermes@example.com")
    confirmation_path()

    signed_at = System.system_time(:second) - 24 * 60 * 60 - 1
    expired = WakeEmail.confirmation_token(Repo.reload!(link), signed_at: signed_at)

    for path <- [~p"/wake-email/confirm/#{expired}", ~p"/wake-email/confirm/forged"] do
      assert build_conn() |> post(path) |> html_response(400) =~ "id=\"wake-email-invalid\""
    end

    refute Links.show_wake_email(Repo.reload!(link)).confirmed
  end

  test "shows and clears the wake email", %{conn: conn, link: link} do
    assert conn |> get(~p"/alp/v1/link/wake_email") |> json_response(200) == %{"wake_email" => nil}

    put_address(conn, "hermes@example.com")
    assert conn |> delete(~p"/alp/v1/link/wake_email") |> response(204)
    assert conn |> delete(~p"/alp/v1/link/wake_email") |> response(204)
    assert conn |> get(~p"/alp/v1/link/wake_email") |> json_response(200) == %{"wake_email" => nil}
    assert Links.show_wake_email(Repo.reload!(link)) == nil
  end

  test "answers 422 invalid_params for an invalid address and sends nothing", %{conn: conn} do
    body = conn |> put(~p"/alp/v1/link/wake_email", %{"address" => "not an address"}) |> json_response(422)
    assert body["error"]["code"] == "invalid_params"
    refute_receive {:email, _email}
  end

  test "requires the Link token" do
    assert build_conn() |> get(~p"/alp/v1/link/wake_email") |> json_response(401)
    assert build_conn() |> put(~p"/alp/v1/link/wake_email", %{"address" => "a@b.c"}) |> json_response(401)
  end
end
