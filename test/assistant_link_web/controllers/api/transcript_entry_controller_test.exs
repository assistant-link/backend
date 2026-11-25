defmodule AssistantLinkWeb.API.TranscriptEntryControllerTest do
  use AssistantLinkWeb.ConnCase, async: true

  import AssistantLink.LinksFixtures

  alias AssistantLink.Accounts
  alias AssistantLink.Calls.TranscriptEntry
  alias AssistantLink.Repo

  setup :register_device

  setup %{conn: conn, scope: scope, account: account} do
    {link, _token} = paired_link_fixture(scope)
    :ok = Accounts.subscribe(account.id)
    %{"call" => call} = conn |> post(~p"/api/v1/assistants/#{link.assistant_id}/calls") |> json_response(201)
    %{assistant_id: link.assistant_id, call_id: call["id"]}
  end

  defp entries_path(assistant_id, call_id),
    do: ~p"/api/v1/assistants/#{assistant_id}/calls/#{call_id}/transcript_entries"

  defp create(conn, ctx, params), do: post(conn, entries_path(ctx.assistant_id, ctx.call_id), params)

  defp update(conn, ctx, id, params), do: patch(conn, entries_path(ctx.assistant_id, ctx.call_id) <> "/#{id}", params)

  defp transcript(conn, ctx), do: get(conn, ~p"/api/v1/assistants/#{ctx.assistant_id}/calls/#{ctx.call_id}/transcript")

  defp error_code(conn, status), do: json_response(conn, status)["error"]["code"]

  defp entry_params(overrides \\ %{}),
    do: Map.merge(%{"speaker" => "user", "text" => "Hi", "started_at" => "2026-11-25T10:00:00.000000Z"}, overrides)

  describe "POST .../transcript_entries" do
    test "saves an entry with the call's next seq and notifies the account", ctx do
      call_id = ctx.call_id

      assert %{"transcript_entry" => first} = ctx.conn |> create(ctx, entry_params()) |> json_response(201)

      assert %{
               "id" => _id,
               "call_id" => ^call_id,
               "seq" => 1,
               "speaker" => "user",
               "text" => "Hi",
               "started_at" => "2026-11-25T10:00:00.000000Z",
               "ended_at" => nil
             } = first

      assert_receive {:call_transcript_entry, %TranscriptEntry{seq: 1, text: "Hi"}}

      overlapping =
        entry_params(%{
          "speaker" => "assistant",
          "text" => "Hello",
          "started_at" => "2026-11-25T09:59:59.500000Z",
          "ended_at" => "2026-11-25T10:00:01.000000Z"
        })

      assert %{"transcript_entry" => %{"seq" => 2, "ended_at" => "2026-11-25T10:00:01.000000Z"}} =
               ctx.conn |> create(ctx, overlapping) |> json_response(201)
    end

    test "takes an id from the app, so a repeated request returns the saved entry", ctx do
      params = entry_params(%{"id" => Ecto.UUID.generate(version: 7)})
      first = ctx.conn |> create(ctx, params) |> json_response(201)

      assert ctx.conn |> create(ctx, Map.put(params, "text", "Hi there")) |> json_response(200) == first
      assert Repo.aggregate(TranscriptEntry, :count) == 1
    end

    test "can save an empty text while speech is still being recognized", ctx do
      assert %{"transcript_entry" => %{"text" => ""}} =
               ctx.conn |> create(ctx, entry_params(%{"text" => ""})) |> json_response(201)
    end

    test "rejects bad params", ctx do
      for params <- [
            entry_params(%{"speaker" => "system"}),
            entry_params(%{"text" => nil}),
            entry_params(%{"text" => "a" <> <<0>>}),
            entry_params(%{"text" => String.duplicate("a", 10_001)}),
            entry_params(%{"started_at" => "yesterday"}),
            entry_params(%{"ended_at" => "2026-11-25T09:00:00Z"}),
            entry_params(%{"id" => Ecto.UUID.generate()}),
            Map.delete(entry_params(), "started_at")
          ] do
        assert error_code(create(ctx.conn, ctx, params), 422) == "invalid_params"
      end

      assert Repo.aggregate(TranscriptEntry, :count) == 0
    end

    test "an unknown call is 404 call_not_found", ctx do
      conn = post(ctx.conn, entries_path(ctx.assistant_id, Ecto.UUID.generate()), entry_params())
      assert error_code(conn, 404) == "call_not_found"
    end
  end

  describe "PATCH .../transcript_entries/:id" do
    test "updates the text and ended_at, keeps the seq, and notifies the account", ctx do
      %{"transcript_entry" => %{"id" => id}} = ctx.conn |> create(ctx, entry_params()) |> json_response(201)
      assert_receive {:call_transcript_entry, _entry}

      params = %{
        "text" => "Hi, how are you?",
        "ended_at" => "2026-11-25T10:00:02Z",
        "seq" => 9,
        "speaker" => "assistant"
      }

      assert %{
               "transcript_entry" => %{
                 "id" => ^id,
                 "seq" => 1,
                 "speaker" => "user",
                 "text" => "Hi, how are you?",
                 "ended_at" => "2026-11-25T10:00:02.000000Z"
               }
             } = ctx.conn |> update(ctx, id, params) |> json_response(200)

      assert_receive {:call_transcript_entry, %TranscriptEntry{id: ^id, text: "Hi, how are you?"}}
    end

    test "works after the call ended", ctx do
      %{"transcript_entry" => %{"id" => id}} = ctx.conn |> create(ctx, entry_params()) |> json_response(201)
      ctx.conn |> post(~p"/api/v1/assistants/#{ctx.assistant_id}/calls/#{ctx.call_id}/end") |> json_response(200)

      assert ctx.conn |> update(ctx, id, %{"text" => "Bye"}) |> json_response(200)
    end

    test "rejects bad params", ctx do
      %{"transcript_entry" => %{"id" => id}} = ctx.conn |> create(ctx, entry_params()) |> json_response(201)

      assert error_code(update(ctx.conn, ctx, id, %{"text" => nil}), 422) == "invalid_params"
      assert error_code(update(ctx.conn, ctx, id, %{"ended_at" => "2026-11-25T09:00:00Z"}), 422) == "invalid_params"
    end

    test "an unknown entry is 404 not_found", ctx do
      assert error_code(update(ctx.conn, ctx, Ecto.UUID.generate(), %{"text" => "Hi"}), 404) == "not_found"
    end
  end

  describe "GET .../transcript" do
    test "lists the entries in order of seq", ctx do
      for text <- ["one", "two", "three"], do: create(ctx.conn, ctx, entry_params(%{"text" => text}))

      assert %{"transcript_entries" => entries} = ctx.conn |> transcript(ctx) |> json_response(200)
      assert Enum.map(entries, &{&1["seq"], &1["text"]}) == [{1, "one"}, {2, "two"}, {3, "three"}]
    end

    test "another account's call is 404", ctx do
      {:ok, %{credential: credential}} = Accounts.register_device()
      other = put_req_header(ctx.conn, "authorization", "Bearer " <> credential)

      assert error_code(transcript(other, ctx), 404) == "not_found"
    end
  end
end
