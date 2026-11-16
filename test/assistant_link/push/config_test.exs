defmodule AssistantLink.Push.ConfigTest do
  # Changes the application's APNs config, so it runs alone.
  use AssistantLinkWeb.ConnCase, async: false

  import AssistantLink.LinksFixtures
  import ExUnit.CaptureLog

  alias AssistantLink.Accounts

  setup :register_device

  setup %{scope: scope} do
    config = Application.fetch_env!(:assistant_link, AssistantLink.Push)
    on_exit(fn -> Application.put_env(:assistant_link, AssistantLink.Push, config) end)

    :ok = Accounts.put_push_token(scope, String.duplicate("ab", 32))
    {_link, link_token} = paired_link_fixture(scope)
    %{config: config, agent: put_req_header(build_conn(), "authorization", "Bearer " <> link_token)}
  end

  defp post_agent_message(agent), do: agent |> post(~p"/alp/v1/messages", %{"text" => "Hi"}) |> json_response(201)

  test "without an APNs key, sending is a logged no-op", %{config: config, agent: agent} do
    Application.put_env(:assistant_link, AssistantLink.Push, Keyword.delete(config, :key_p8))

    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)

    log = capture_log([level: :info], fn -> post_agent_message(agent) end)

    assert log =~ "APNs is not configured"
    refute_receive {:apns_request, _pid, _url, _headers, _body}
  end

  test "sends to the sandbox when configured", %{config: config, agent: agent} do
    Application.put_env(:assistant_link, AssistantLink.Push, Keyword.put(config, :env, :sandbox))

    post_agent_message(agent)

    assert_receive {:apns_request, _pid, "https://api.sandbox.push.apple.com/3/device/" <> _token, _headers, _body},
                   1000
  end
end
