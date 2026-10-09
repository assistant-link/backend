defmodule AssistantLinkWeb.JSONRPCTest do
  use ExUnit.Case, async: true

  alias AssistantLinkWeb.JSONRPC

  defp frame(message), do: Jason.encode!(message)

  defp error_code({:error, %{error: %{code: code}}}), do: code

  describe "decode/1" do
    test "a request, with or without params" do
      assert JSONRPC.decode(frame(%{jsonrpc: "2.0", id: 1, method: "a.b", params: %{x: 1}})) ==
               {:ok, {:request, 1, "a.b", %{"x" => 1}}}

      assert JSONRPC.decode(frame(%{jsonrpc: "2.0", id: "r1", method: "a.b"})) == {:ok, {:request, "r1", "a.b", %{}}}

      assert JSONRPC.decode(frame(%{jsonrpc: "2.0", id: nil, method: "a.b", params: [1]})) ==
               {:ok, {:request, nil, "a.b", [1]}}
    end

    test "a notification has no id" do
      assert JSONRPC.decode(frame(%{jsonrpc: "2.0", method: "a.b"})) == {:ok, {:notification, "a.b", %{}}}
    end

    test "a response carries a result or an error" do
      assert JSONRPC.decode(frame(%{jsonrpc: "2.0", id: 7, result: nil})) == {:ok, {:response, 7, {:ok, nil}}}

      error = %{"code" => -32_601, "message" => "Method not found"}
      assert JSONRPC.decode(frame(%{jsonrpc: "2.0", id: 7, error: error})) == {:ok, {:response, 7, {:error, error}}}
    end

    test "unknown members are ignored" do
      assert JSONRPC.decode(frame(%{jsonrpc: "2.0", method: "a.b", extra: true})) == {:ok, {:notification, "a.b", %{}}}
    end

    test "invalid JSON is a parse error (-32700) with a null id" do
      assert {:error, %{jsonrpc: "2.0", id: nil, error: %{code: -32_700}}} = JSONRPC.decode(~s({"jsonrpc": "2.0",))
    end

    test "a batch is an invalid request (-32600) with a null id" do
      batch = frame([%{jsonrpc: "2.0", id: 1, method: "a.b"}])

      assert {:error, %{id: nil, error: %{code: -32_600, message: "Invalid request: batches are not supported."}}} =
               JSONRPC.decode(batch)
    end

    test "other invalid messages are invalid requests (-32600)" do
      for message <- [
            "a string",
            %{id: 1, method: "a.b"},
            %{jsonrpc: "1.0", id: 1, method: "a.b"},
            %{jsonrpc: "2.0", id: 1, method: 3},
            %{jsonrpc: "2.0", id: 1, method: "a.b", params: "x"},
            %{jsonrpc: "2.0", id: %{}, method: "a.b"},
            %{jsonrpc: "2.0", id: 1},
            %{jsonrpc: "2.0", id: 1, result: 1, error: %{code: 1, message: "m"}},
            %{jsonrpc: "2.0", id: 1, error: %{code: "x", message: "m"}}
          ] do
        assert message |> frame() |> JSONRPC.decode() |> error_code() == -32_600
      end
    end

    test "an invalid request echoes its id when the id itself is valid" do
      assert {:error, %{id: 5}} = JSONRPC.decode(frame(%{jsonrpc: "2.0", id: 5, method: 3}))
      assert {:error, %{id: nil}} = JSONRPC.decode(frame(%{jsonrpc: "2.0", id: [5], method: "a.b"}))
    end
  end

  describe "reply/2" do
    defp route("echo", %{"text" => text}) when is_binary(text), do: {:ok, %{text: text}}
    defp route("echo", _params), do: {:error, JSONRPC.invalid_params("text must be a string")}
    defp route("fail", _params), do: {:error, JSONRPC.server_error(-32_001, "not_ready", "Not ready.")}
    defp route(method, params), do: JSONRPC.no_methods(method, params)

    defp reply(message), do: message |> frame() |> JSONRPC.reply(&route/2)

    test "answers a request with the route's result" do
      assert reply(%{jsonrpc: "2.0", id: 1, method: "echo", params: %{text: "hi"}}) ==
               %{jsonrpc: "2.0", id: 1, result: %{text: "hi"}}
    end

    test "an unknown method is method not found (-32601)" do
      assert reply(%{jsonrpc: "2.0", id: 1, method: "something.new"}) == %{
               jsonrpc: "2.0",
               id: 1,
               error: %{code: -32_601, message: "Method not found: something.new"}
             }
    end

    test "the route's invalid params is -32602" do
      assert %{id: 2, error: %{code: -32_602}} = reply(%{jsonrpc: "2.0", id: 2, method: "echo", params: %{text: 1}})
    end

    test "a server error carries its reason in data.reason" do
      assert reply(%{jsonrpc: "2.0", id: 3, method: "fail"}) == %{
               jsonrpc: "2.0",
               id: 3,
               error: %{code: -32_001, message: "Not ready.", data: %{reason: "not_ready"}}
             }
    end

    test "answers an invalid frame with its error" do
      assert %{id: nil, error: %{code: -32_700}} = JSONRPC.reply("not json", &route/2)
    end

    test "notifications and responses get no answer" do
      assert reply(%{jsonrpc: "2.0", method: "something.new"}) == nil
      assert reply(%{jsonrpc: "2.0", id: 1, result: true}) == nil
    end
  end

  test "server errors use the -32000..-32099 range" do
    assert_raise FunctionClauseError, fn -> JSONRPC.server_error(-32_100, "x", "x") end
    assert_raise FunctionClauseError, fn -> JSONRPC.server_error(-31_999, "x", "x") end
  end

  test "encoded messages decode as the same message" do
    for {message, decoded} <- [
          {JSONRPC.request(4, "call.accept", %{id: "c1"}), {:request, 4, "call.accept", %{"id" => "c1"}}},
          {JSONRPC.notification("link.status", %{status: "online"}),
           {:notification, "link.status", %{"status" => "online"}}},
          {JSONRPC.result_response("r1", %{ok: true}), {:response, "r1", {:ok, %{"ok" => true}}}},
          {JSONRPC.error_response(5, JSONRPC.method_not_found("x")),
           {:response, 5, {:error, %{"code" => -32_601, "message" => "Method not found: x"}}}}
        ] do
      assert message |> JSONRPC.encode!() |> IO.iodata_to_binary() |> JSONRPC.decode() == {:ok, decoded}
    end
  end

  test "encode!/1 encodes a notification" do
    encoded = "connection.ready" |> JSONRPC.notification(%{protocol_version: "1"}) |> JSONRPC.encode!()

    assert Jason.decode!(encoded) == %{
             "jsonrpc" => "2.0",
             "method" => "connection.ready",
             "params" => %{"protocol_version" => "1"}
           }
  end
end
