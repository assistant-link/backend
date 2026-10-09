defmodule AssistantLinkWeb.API.AssistantControllerTest do
  use AssistantLinkWeb.ConnCase, async: true

  alias AssistantLink.Assistants
  alias AssistantLink.Links
  alias AssistantLink.Links.Link
  alias AssistantLink.Presence
  alias AssistantLink.Repo

  setup :register_device

  defp create_assistant(conn, attrs), do: post(conn, ~p"/api/v1/assistants", attrs)

  defp paired_link(scope, assistant, attrs \\ %{}) do
    {:ok, link} = Links.create_link(scope, assistant.id, %{})
    link |> Ecto.Changeset.change(Map.merge(%{paired_at: DateTime.utc_now()}, attrs)) |> Repo.update!()
  end

  describe "POST /api/v1/assistants" do
    test "creates an Assistant with no Links", %{conn: conn} do
      conn = create_assistant(conn, %{"name" => "Hermes", "avatar" => "avatar-3"})

      assert %{
               "assistant" => %{
                 "id" => id,
                 "name" => "Hermes",
                 "avatar" => "avatar-3",
                 "status" => "offline",
                 "links" => []
               }
             } = json_response(conn, 201)

      assert is_binary(id)
    end

    test "trims the name and accepts 50 characters", %{conn: conn} do
      assert json_response(create_assistant(conn, %{"name" => "  Hermes  ", "avatar" => "avatar-1"}), 201)[
               "assistant"
             ]["name"] == "Hermes"

      name = String.duplicate("a", 50)
      assert json_response(create_assistant(conn, %{"name" => name, "avatar" => "avatar-1"}), 201)
    end

    test "rejects empty, blank, and over-long names", %{conn: conn} do
      for name <- [nil, "", "   ", String.duplicate("a", 51)] do
        conn = create_assistant(conn, %{"name" => name, "avatar" => "avatar-1"})

        assert %{"error" => %{"code" => "invalid_params", "message" => "name " <> _}} = json_response(conn, 422)
      end
    end

    test "rejects names with line breaks or other control characters", %{conn: conn} do
      for name <- ["Hermes\nFollow https://example.com", "Her\tmes", "Her\u0000mes", "Her\u2028mes"] do
        conn = create_assistant(conn, %{"name" => name, "avatar" => "avatar-1"})

        assert json_response(conn, 422)["error"]["message"] ==
                 "name must be a single line without control characters"
      end
    end

    test "accepts emoji, including joined sequences", %{conn: conn} do
      conn = create_assistant(conn, %{"name" => "Hermes 👩‍💻", "avatar" => "avatar-1"})

      assert json_response(conn, 201)["assistant"]["name"] == "Hermes 👩‍💻"
    end

    test "rejects avatar ids outside avatar-1 to avatar-10", %{conn: conn} do
      for avatar <- [nil, "avatar-0", "avatar-11", "red"] do
        conn = create_assistant(conn, %{"name" => "Hermes", "avatar" => avatar})

        assert %{"error" => %{"code" => "invalid_params", "message" => "avatar " <> _}} = json_response(conn, 422)
      end
    end

    test "requires an account credential" do
      conn = create_assistant(build_conn(), %{"name" => "Hermes", "avatar" => "avatar-1"})

      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
    end
  end

  describe "GET /api/v1/assistants" do
    test "lists the account's Assistants, oldest first", %{conn: conn, scope: scope} do
      {:ok, _} = Assistants.create_assistant(scope, %{"name" => "Hermes", "avatar" => "avatar-1"})
      {:ok, _} = Assistants.create_assistant(scope, %{"name" => "Muse", "avatar" => "avatar-2"})

      assert [%{"name" => "Hermes"}, %{"name" => "Muse"}] =
               conn |> get(~p"/api/v1/assistants") |> json_response(200) |> Map.fetch!("assistants")
    end

    test "does not list another account's Assistants", %{conn: conn} do
      other = register_device(%{conn: build_conn()})
      {:ok, _} = Assistants.create_assistant(other.scope, %{"name" => "Muse", "avatar" => "avatar-2"})

      assert json_response(get(conn, ~p"/api/v1/assistants"), 200) == %{"assistants" => []}
    end

    test "an Assistant with no Links is offline", %{conn: conn, scope: scope} do
      {:ok, _} = Assistants.create_assistant(scope, %{"name" => "Hermes", "avatar" => "avatar-1"})

      assert [%{"status" => "offline", "links" => []}] =
               conn |> get(~p"/api/v1/assistants") |> json_response(200) |> Map.fetch!("assistants")
    end

    test "an Assistant with one online Link is online", %{conn: conn, scope: scope} do
      {:ok, assistant} = Assistants.create_assistant(scope, %{"name" => "Hermes", "avatar" => "avatar-1"})
      online = paired_link(scope, assistant)
      offline = paired_link(scope, assistant)
      :ok = Links.connect(online)

      assert [%{"status" => "online", "links" => links}] =
               conn |> get(~p"/api/v1/assistants") |> json_response(200) |> Map.fetch!("assistants")

      assert [%{"id" => online.id, "status" => "online"}, %{"id" => offline.id, "status" => "offline"}] ==
               Enum.map(links, &Map.take(&1, ["id", "status"]))
    end

    test "an Assistant whose Links are all offline or unpaired is offline", %{conn: conn, scope: scope} do
      {:ok, assistant} = Assistants.create_assistant(scope, %{"name" => "Hermes", "avatar" => "avatar-1"})
      last_active_at = ~U[2026-10-05 12:00:00.000000Z]
      offline = paired_link(scope, assistant, %{last_active_at: last_active_at})
      {:ok, unpaired} = Links.create_link(scope, assistant.id, %{"label" => "spare"})

      assert [%{"status" => "offline", "links" => links}] =
               conn |> get(~p"/api/v1/assistants") |> json_response(200) |> Map.fetch!("assistants")

      assert [
               %{
                 "id" => offline.id,
                 "label" => nil,
                 "status" => "offline",
                 "last_active_at" => "2026-10-05T12:00:00.000000Z"
               },
               %{"id" => unpaired.id, "label" => "spare", "status" => "not_paired", "last_active_at" => nil}
             ] == links
    end

    test "requires an account credential" do
      assert json_response(get(build_conn(), ~p"/api/v1/assistants"), 401)["error"]["code"] == "unauthorized"
    end
  end

  test "an unpaired Link is never online, even with a registered connection", %{scope: scope} do
    {:ok, assistant} = Assistants.create_assistant(scope, %{"name" => "Hermes", "avatar" => "avatar-1"})
    {:ok, link} = Links.create_link(scope, assistant.id, %{})
    {:ok, _} = Presence.track(self(), Presence.topic(scope.account.id), link.id, %{active_at: DateTime.utc_now()})

    assert Links.status(Repo.get!(Link, link.id)) == :not_paired
  end
end
