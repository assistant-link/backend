defmodule AssistantLinkWeb.ALP.AssistantControllerTest do
  use AssistantLinkWeb.ConnCase, async: true

  import AssistantLink.LinksFixtures

  alias AssistantLink.Accounts
  alias AssistantLink.Assistants

  setup :register_device

  setup %{conn: conn, scope: scope, account: account} do
    {link, token} = paired_link_fixture(scope)
    :ok = Accounts.subscribe(account.id)
    %{conn: put_req_header(conn, "authorization", "Bearer " <> token), link: link}
  end

  defp show(conn), do: conn |> get(~p"/alp/v1/assistant") |> json_response(200)

  defp update(conn, params), do: conn |> patch(~p"/alp/v1/assistant", params) |> json_response(200)

  defp update_error(conn, params), do: conn |> patch(~p"/alp/v1/assistant", params) |> json_response(422)

  test "GET shows the Assistant's name and platform, null until set", %{conn: conn} do
    assert show(conn) == %{"name" => "Hermes", "platform" => nil}
  end

  describe "PATCH /alp/v1/assistant" do
    test "sets the platform and keeps the name", %{conn: conn} do
      assert update(conn, %{"platform" => "openclaw"}) == %{"name" => "Hermes", "platform" => "openclaw"}
      assert show(conn) == %{"name" => "Hermes", "platform" => "openclaw"}
    end

    test "stores each known platform trimmed and lowercased", %{conn: conn} do
      for platform <- ~w(muse grokbot dots duet hermes openclaw instinct) do
        assert update(conn, %{"platform" => "  " <> String.upcase(platform) <> " "})["platform"] == platform
      end
    end

    test "stores any other platform trimmed but otherwise verbatim", %{conn: conn} do
      assert update(conn, %{"platform" => "  My Own Bot 🤖 "})["platform"] == "My Own Bot 🤖"
    end

    test "clears the platform for null or blank", %{conn: conn} do
      for platform <- [nil, "", "  "] do
        update(conn, %{"platform" => "muse"})
        assert update(conn, %{"platform" => platform})["platform"] == nil
      end
    end

    test "renames the Assistant and keeps the platform", %{conn: conn} do
      update(conn, %{"platform" => "muse"})

      assert update(conn, %{"name" => "  Athena "}) == %{"name" => "Athena", "platform" => "muse"}
      assert show(conn) == %{"name" => "Athena", "platform" => "muse"}
    end

    test "answers with the stored values when another request changed the other field meanwhile", %{link: link} do
      {:ok, _assistant} = Assistants.update_assistant(link.assistant, %{"name" => "Athena"})

      assert {:ok, %{name: "Athena", platform: "muse"}} =
               Assistants.update_assistant(link.assistant, %{"platform" => "muse"})
    end

    test "sets both in one request", %{conn: conn} do
      assert update(conn, %{"name" => "Athena", "platform" => "Dots"}) == %{"name" => "Athena", "platform" => "dots"}
    end

    test "changes nothing without either field", %{conn: conn} do
      assert update(conn, %{}) == %{"name" => "Hermes", "platform" => nil}
      refute_received {:assistant_updated, _assistant}
    end

    test "tells the account's subscribers what changed", %{conn: conn, link: link} do
      assistant_id = link.assistant_id

      update(conn, %{"name" => "Athena"})
      assert_receive {:assistant_updated, %{id: ^assistant_id, name: "Athena", platform: nil}}

      update(conn, %{"name" => "Athena", "platform" => "muse"})
      assert_receive {:assistant_updated, %{id: ^assistant_id, name: "Athena", platform: "muse"}}

      update(conn, %{"name" => "Athena"})
      refute_received {:assistant_updated, _assistant}
    end

    test "validates the name as creating an Assistant does, and changes nothing", %{conn: conn} do
      for name <- [nil, "", "   ", String.duplicate("a", 51), "Her\nmes", 1] do
        assert %{"error" => %{"code" => "invalid_params", "message" => "name " <> _}} =
                 update_error(conn, %{"name" => name, "platform" => "muse"})
      end

      assert show(conn) == %{"name" => "Hermes", "platform" => nil}
      refute_received {:assistant_updated, _assistant}
    end

    test "accepts a platform of 50 characters and rejects a longer, multi-line, or non-string one", %{conn: conn} do
      fifty = String.duplicate("é", 50)
      assert update(conn, %{"platform" => fifty})["platform"] == fifty

      assert update_error(conn, %{"platform" => fifty <> "é"})["error"] ==
               %{"code" => "invalid_params", "message" => "platform should be at most 50 character(s)"}

      assert update_error(conn, %{"platform" => "my\nbot"})["error"]["message"] ==
               "platform must be a single line without control characters"

      assert update_error(conn, %{"platform" => 1})["error"]["message"] == "platform is invalid"
    end
  end

  test "requires the Link token" do
    for request <- [&get(&1, ~p"/alp/v1/assistant"), &patch(&1, ~p"/alp/v1/assistant", %{"name" => "Athena"})] do
      assert %{"error" => %{"code" => "unauthorized"}} = build_conn() |> request.() |> json_response(401)
    end
  end
end
