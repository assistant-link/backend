defmodule AssistantLinkWeb.ALP.PairControllerTest do
  use AssistantLinkWeb.ConnCase, async: true

  import Ecto.Query

  alias AssistantLink.Accounts
  alias AssistantLink.Assistants
  alias AssistantLink.Links
  alias AssistantLink.Links.Link
  alias AssistantLink.Links.PairingCode
  alias AssistantLink.Repo
  alias AssistantLink.Tokens

  setup %{conn: conn} do
    %{scope: scope} = register_device(%{conn: conn})
    {:ok, assistant} = Assistants.create_assistant(scope, %{"name" => "Hermes", "avatar" => "avatar-1"})
    {:ok, link} = Links.create_link(scope, assistant.id, %{"label" => "laptop"})
    {:ok, %{code: code}} = Links.issue_pairing_code(scope, link.id)

    %{scope: scope, assistant: assistant, link: link, code: code}
  end

  defp pair(code), do: post(build_conn(), ~p"/alp/v1/pair", %{"code" => code})

  defp error_code(conn, status), do: json_response(conn, status)["error"]["code"]

  test "a valid code pairs the Link and returns its token", %{link: link, code: code} do
    assert %{"link_id" => link_id, "assistant_name" => "Hermes", "token" => "alt_" <> _ = token} =
             code |> pair() |> json_response(200)

    assert link_id == link.id
    assert %Link{id: ^link_id, paired_at: %DateTime{}} = Links.get_link_by_token(token)
    assert %PairingCode{used_at: %DateTime{}} = Repo.one!(PairingCode)
  end

  test "stores only the token's hash", %{link: link, code: code} do
    %{"token" => token} = code |> pair() |> json_response(200)

    assert Repo.get!(Link, link.id).token_hash == Tokens.hash(token)
  end

  test "accepts the code however it is typed", %{code: code} do
    reformatted = code |> String.downcase() |> String.replace("-", " - ")

    assert %{"token" => _} = reformatted |> pair() |> json_response(200)
  end

  test "a used code is invalid", %{code: code} do
    json_response(pair(code), 200)

    assert code |> pair() |> error_code(422) == "invalid_code"
  end

  test "an unknown or empty code is invalid" do
    for code <- ["0000-0000", ""] do
      assert code |> pair() |> error_code(422) == "invalid_code"
    end
  end

  test "a code of a deleted account is invalid, like an unknown code", %{scope: scope, code: code} do
    :ok = Accounts.delete_account(scope)

    assert code |> pair() |> error_code(422) == "invalid_code"
    assert Repo.one!(PairingCode).used_at == nil
    assert Repo.one!(Link).paired_at == nil
  end

  test "a replaced code is invalid", %{scope: scope, link: link, code: code} do
    {:ok, _new_code} = Links.issue_pairing_code(scope, link.id)

    assert code |> pair() |> error_code(422) == "invalid_code"
  end

  test "an expired code is rejected and pairs nothing", %{link: link, code: code} do
    Repo.update_all(PairingCode, set: [expires_at: DateTime.shift(DateTime.utc_now(), minute: -1)])

    assert code |> pair() |> error_code(422) == "expired_code"
    assert %Link{paired_at: nil, token_hash: nil} = Repo.get!(Link, link.id)
  end

  test "a missing or non-string code is invalid params" do
    for body <- [%{}, %{"code" => 12_345_678}] do
      assert build_conn() |> post(~p"/alp/v1/pair", body) |> error_code(422) == "invalid_params"
    end
  end

  test "pairing another Link leaves the first Link's token working", context do
    %{"token" => first_token} = context.code |> pair() |> json_response(200)

    {:ok, other_link} = Links.create_link(context.scope, context.assistant.id, %{"label" => "cloud"})
    {:ok, %{code: other_code}} = Links.issue_pairing_code(context.scope, other_link.id)
    %{"link_id" => other_link_id} = other_code |> pair() |> json_response(200)

    assert other_link_id == other_link.id
    assert Links.get_link_by_token(first_token).id == context.link.id
    assert Repo.aggregate(from(l in Link, where: not is_nil(l.paired_at)), :count) == 2
  end
end
