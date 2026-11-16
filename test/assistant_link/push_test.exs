defmodule AssistantLink.PushTest do
  use AssistantLinkWeb.ConnCase, async: true

  import AssistantLink.LinksFixtures

  alias AssistantLink.Accounts
  alias AssistantLink.Accounts.Device
  alias AssistantLink.Events
  alias AssistantLink.Repo

  @token String.duplicate("ab", 32)

  setup :register_device

  setup %{scope: scope} do
    :ok = Accounts.put_push_token(scope, @token)
    {link, link_token} = paired_link_fixture(scope, "Hermes")
    agent = put_req_header(build_conn(), "authorization", "Bearer " <> link_token)
    %{link: link, agent: agent, assistant: Repo.preload(link, :assistant).assistant}
  end

  defp post_agent_message(agent, text, key \\ nil) do
    params = if key, do: %{"text" => text, "idempotency_key" => key}, else: %{"text" => text}
    agent |> post(~p"/alp/v1/messages", params) |> json_response(201)
  end

  defp call_event(scope, assistant, type) do
    params = %{"type" => type, "idempotency_key" => Ecto.UUID.generate(version: 7)}
    {:ok, _event, :created} = Events.create_call_event(scope, assistant.id, params)
  end

  defp await_finished(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
  end

  defp decode_segment(segment), do: segment |> Base.url_decode64!(padding: false) |> Jason.decode!()

  test "pushes a new agent message to the account's devices", %{agent: agent, link: link, assistant: assistant} do
    %{"message_id" => event_id} = post_agent_message(agent, "Your reminder is set.")

    assert_receive {:apns_request, _pid, url, headers, body}, 1000
    assert url == "https://api.push.apple.com/3/device/" <> @token

    assert %{
             "apns-topic" => "ai.assistantlink.app",
             "apns-push-type" => "alert",
             "apns-priority" => "10",
             "apns-id" => ^event_id,
             "authorization" => "bearer " <> _jwt
           } = Map.new(headers)

    assert Jason.decode!(body) == %{
             "aps" => %{
               "alert" => %{"title" => "Hermes", "body" => "Your reminder is set."},
               "sound" => "default",
               "thread-id" => link.id
             },
             "link_id" => link.id,
             "assistant_id" => assistant.id,
             "event_id" => event_id
           }
  end

  test "signs an ES256 provider token and reuses it", %{agent: agent} do
    post_agent_message(agent, "One")
    assert_receive {:apns_request, _pid, _url, headers, _body}, 1000
    "bearer " <> jwt = Map.new(headers)["authorization"]

    [header, claims, signature] = String.split(jwt, ".")
    assert decode_segment(header) == %{"alg" => "ES256", "kid" => "KEY1234567"}
    assert %{"iss" => "TEAM123456", "iat" => iat} = decode_segment(claims)
    assert_in_delta iat, System.system_time(:second), 3600

    {:ECPrivateKey, _version, _private, params, public, _attributes} = signing_key()
    <<r::256, s::256>> = Base.url_decode64!(signature, padding: false)
    der = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})
    assert :public_key.verify(header <> "." <> claims, :sha256, der, {{:ECPoint, public}, params})

    post_agent_message(agent, "Two")
    assert_receive {:apns_request, _pid, _url, headers, _body}, 1000
    assert Map.new(headers)["authorization"] == "bearer " <> jwt
  end

  defp signing_key do
    [entry] = :public_key.pem_decode(Application.fetch_env!(:assistant_link, AssistantLink.Push)[:key_p8])
    :public_key.pem_entry_decode(entry)
  end

  test "truncates a long message to about 150 characters", %{agent: agent} do
    post_agent_message(agent, String.duplicate("word ", 100))

    assert_receive {:apns_request, _pid, _url, _headers, body}, 1000
    preview = Jason.decode!(body)["aps"]["alert"]["body"]
    assert String.length(preview) <= 150
    assert String.ends_with?(preview, "word…")
  end

  test "pushes to every device of the account and no other", %{agent: agent, scope: scope} do
    second = Repo.insert!(%Device{account_id: scope.account.id, user_id: scope.user.id, token_hash: "second"})
    second_token = String.duplicate("cd", 32)
    :ok = Accounts.put_push_token(%{scope | device: second}, second_token)

    %{scope: other_scope} = register_device(%{conn: build_conn()})
    :ok = Accounts.put_push_token(other_scope, String.duplicate("ef", 32))

    post_agent_message(agent, "Hi")

    assert_receive {:apns_request, _pid, first_url, _headers, _body}, 1000
    assert_receive {:apns_request, _pid, second_url, _headers, _body}, 1000
    assert Enum.sort([first_url, second_url]) == Enum.map([@token, second_token], &device_url/1)
    refute_receive {:apns_request, _pid, _url, _headers, _body}
  end

  defp device_url(token), do: "https://api.push.apple.com/3/device/" <> token

  test "does not push a repeated agent message", %{agent: agent} do
    key = Ecto.UUID.generate(version: 7)
    post_agent_message(agent, "Hi", key)
    assert_receive {:apns_request, _pid, _url, _headers, _body}, 1000

    agent |> post(~p"/alp/v1/messages", %{"text" => "Hi", "idempotency_key" => key}) |> json_response(200)
    refute_receive {:apns_request, _pid, _url, _headers, _body}
  end

  test "does not push the user's own messages", %{conn: conn, assistant: assistant} do
    params = %{"text" => "Hi", "idempotency_key" => Ecto.UUID.generate(version: 7)}
    conn |> post(~p"/api/v1/assistants/#{assistant.id}/messages", params) |> json_response(201)
    refute_receive {:apns_request, _pid, _url, _headers, _body}
  end

  test "does not push while the Assistant is on a call", %{agent: agent, scope: scope, assistant: assistant} do
    call_event(scope, assistant, "call_started")
    post_agent_message(agent, "Spoken already")
    refute_receive {:apns_request, _pid, _url, _headers, _body}

    call_event(scope, assistant, "call_ended")
    post_agent_message(agent, "After the call")
    assert_receive {:apns_request, _pid, _url, _headers, _body}, 1000
  end

  test "pushes again once a call_started without call_ended is over an hour old",
       %{agent: agent, scope: scope, assistant: assistant} do
    {:ok, event, :created} = call_event(scope, assistant, "call_started")
    stale_at = DateTime.shift(DateTime.utc_now(), minute: -61)

    post_agent_message(agent, "Spoken already")
    refute_receive {:apns_request, _pid, _url, _headers, _body}

    event |> Ecto.Changeset.change(inserted_at: stale_at) |> Repo.update!()
    post_agent_message(agent, "The call never ended")
    assert_receive {:apns_request, _pid, _url, _headers, _body}, 1000
  end

  test "does not push when no device registered a token", %{agent: agent, scope: scope} do
    :ok = Accounts.delete_push_token(scope)
    post_agent_message(agent, "Hi")
    refute_receive {:apns_request, _pid, _url, _headers, _body}
  end

  for {prefix, answer} <- [{"410", "Unregistered"}, {"400", "BadDeviceToken"}] do
    test "drops a token APNs answers #{answer} for", %{agent: agent, scope: scope} do
      token = unquote(prefix) <> String.duplicate("a", 61)
      :ok = Accounts.put_push_token(scope, token)

      post_agent_message(agent, "Hi")
      assert_receive {:apns_request, pid, _url, _headers, _body}, 1000
      await_finished(pid)

      assert Repo.get!(Device, scope.device.id).push_token == nil
    end
  end

  test "keeps a token on other errors", %{agent: agent, scope: scope} do
    token = "500" <> String.duplicate("a", 61)
    :ok = Accounts.put_push_token(scope, token)

    ExUnit.CaptureLog.capture_log(fn ->
      post_agent_message(agent, "Hi")
      assert_receive {:apns_request, pid, _url, _headers, _body}, 1000
      await_finished(pid)
    end)

    assert Repo.get!(Device, scope.device.id).push_token == token
  end
end
