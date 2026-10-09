defmodule AssistantLinkWeb.API.LinkControllerTest do
  use AssistantLinkWeb.ConnCase, async: true

  import Ecto.Query

  alias AssistantLink.Assistants
  alias AssistantLink.Links
  alias AssistantLink.Links.Link
  alias AssistantLink.Links.PairingCode
  alias AssistantLink.Repo
  alias AssistantLink.Tokens

  setup :register_device

  setup %{scope: scope} do
    {:ok, assistant} = Assistants.create_assistant(scope, %{"name" => "Hermes", "avatar" => "avatar-1"})
    %{assistant: assistant}
  end

  defp issue_code(conn, link_id), do: post(conn, ~p"/api/v1/links/#{link_id}/pairing_code")

  describe "POST /api/v1/assistants/:assistant_id/links" do
    test "creates an unpaired Link with a label", %{conn: conn, assistant: assistant} do
      conn = post(conn, ~p"/api/v1/assistants/#{assistant.id}/links", %{"label" => "laptop"})

      assert %{"link" => %{"id" => _, "label" => "laptop", "status" => "not_paired", "last_active_at" => nil}} =
               json_response(conn, 201)
    end

    test "the label is optional", %{conn: conn, assistant: assistant} do
      for params <- [%{}, %{"label" => ""}, %{"label" => "   "}] do
        conn = post(conn, ~p"/api/v1/assistants/#{assistant.id}/links", params)

        assert json_response(conn, 201)["link"]["label"] == nil
      end
    end

    test "accepts a label of up to 50 characters", %{conn: conn, assistant: assistant} do
      label = String.duplicate("a", 50)
      conn = post(conn, ~p"/api/v1/assistants/#{assistant.id}/links", %{"label" => label})

      assert json_response(conn, 201)["link"]["label"] == label
    end

    test "rejects over-long labels and labels with control characters", %{conn: conn, assistant: assistant} do
      for label <- [String.duplicate("a", 51), "laptop\nsecond line", "lap\ttop"] do
        conn = post(conn, ~p"/api/v1/assistants/#{assistant.id}/links", %{"label" => label})

        assert %{"error" => %{"code" => "invalid_params", "message" => "label " <> _}} = json_response(conn, 422)
      end

      assert Repo.aggregate(Link, :count) == 0
    end

    test "another account's Assistant or an unknown id is not found", %{conn: conn} do
      other = register_device(%{conn: build_conn()})
      {:ok, other_assistant} = Assistants.create_assistant(other.scope, %{"name" => "Muse", "avatar" => "avatar-2"})

      for id <- [other_assistant.id, Ecto.UUID.generate(), "not-a-uuid"] do
        conn = post(conn, ~p"/api/v1/assistants/#{id}/links", %{})

        assert json_response(conn, 404)["error"]["code"] == "not_found"
      end

      assert Repo.aggregate(Link, :count) == 0
    end
  end

  describe "POST /api/v1/links/:link_id/pairing_code" do
    setup %{scope: scope, assistant: assistant} do
      {:ok, link} = Links.create_link(scope, assistant.id, %{})
      %{link: link}
    end

    test "issues a code that expires in 15 minutes, with pairing text", %{conn: conn, link: link} do
      before = DateTime.utc_now()
      conn = issue_code(conn, link.id)

      assert %{"code" => code, "expires_at" => expires_at, "pairing_text" => text} = json_response(conn, 201)
      assert code =~ ~r/\A[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}\z/

      {:ok, expires_at, 0} = DateTime.from_iso8601(expires_at)
      assert DateTime.diff(expires_at, before, :second) in 899..901

      service_url = AssistantLinkWeb.Endpoint.url()

      assert text == """
             Connect to my assistant "Hermes" on Assistant Link.
             Follow the instructions at #{service_url}/install.md
             Service: #{service_url}
             Pairing code: #{code} (expires #{Calendar.strftime(expires_at, "%H:%M")} UTC)
             """
    end

    test "stores only the code's hash", %{conn: conn, link: link} do
      %{"code" => code} = conn |> issue_code(link.id) |> json_response(201)

      assert [%PairingCode{code_hash: hash, used_at: nil}] = Repo.all(PairingCode)
      assert hash == Tokens.hash(Tokens.normalize_code(code))
    end

    test "a new code replaces the previous unused one", %{conn: conn, link: link} do
      %{"code" => first} = conn |> issue_code(link.id) |> json_response(201)
      %{"code" => second} = conn |> issue_code(link.id) |> json_response(201)

      hashes = Repo.all(from c in PairingCode, select: c.code_hash)
      assert hashes == [Tokens.hash(Tokens.normalize_code(second))]
      refute Tokens.hash(Tokens.normalize_code(first)) in hashes
    end

    test "a paired Link gets no code", %{conn: conn, link: link} do
      link |> Ecto.Changeset.change(paired_at: DateTime.utc_now()) |> Repo.update!()

      conn = issue_code(conn, link.id)

      assert json_response(conn, 409)["error"]["code"] == "already_paired"
      assert Repo.aggregate(PairingCode, :count) == 0
    end

    test "another account's Link or an unknown id is not found", %{conn: conn, link: link} do
      other = register_device(%{conn: build_conn()})

      for {conn, id} <- [{other.conn, link.id}, {conn, Ecto.UUID.generate()}, {conn, "not-a-uuid"}] do
        assert json_response(issue_code(conn, id), 404)["error"]["code"] == "not_found"
      end
    end

    test "requires an account credential", %{link: link} do
      assert json_response(issue_code(build_conn(), link.id), 401)["error"]["code"] == "unauthorized"
    end
  end
end
