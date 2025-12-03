defmodule Hermolaos.Protocol.JsonRpcTest do
  use ExUnit.Case, async: true

  alias Hermolaos.Protocol.JsonRpc

  describe "encode_request/3" do
    test "creates valid JSON-RPC request with params" do
      json = JsonRpc.encode_request(1, "tools/list", %{"cursor" => "abc"})
      decoded = Jason.decode!(json)

      assert decoded["jsonrpc"] == "2.0"
      assert decoded["id"] == 1
      assert decoded["method"] == "tools/list"
      assert decoded["params"] == %{"cursor" => "abc"}
    end

    test "creates request without params when nil" do
      json = JsonRpc.encode_request(42, "ping", nil)
      decoded = Jason.decode!(json)

      assert decoded["jsonrpc"] == "2.0"
      assert decoded["id"] == 42
      assert decoded["method"] == "ping"
      refute Map.has_key?(decoded, "params")
    end

    test "supports string IDs" do
      json = JsonRpc.encode_request("req-123", "ping", nil)
      decoded = Jason.decode!(json)

      assert decoded["id"] == "req-123"
    end
  end

  describe "encode_notification/2" do
    test "creates notification without id" do
      json = JsonRpc.encode_notification("notifications/initialized", %{})
      decoded = Jason.decode!(json)

      assert decoded["jsonrpc"] == "2.0"
      assert decoded["method"] == "notifications/initialized"
      refute Map.has_key?(decoded, "id")
    end

    test "creates notification without params when nil" do
      json = JsonRpc.encode_notification("notifications/initialized", nil)
      decoded = Jason.decode!(json)

      refute Map.has_key?(decoded, "params")
    end
  end

  describe "encode_response/2" do
    test "creates success response" do
      json = JsonRpc.encode_response(1, %{"tools" => []})
      decoded = Jason.decode!(json)

      assert decoded["jsonrpc"] == "2.0"
      assert decoded["id"] == 1
      assert decoded["result"] == %{"tools" => []}
      refute Map.has_key?(decoded, "error")
    end
  end

  describe "encode_error_response/4" do
    test "creates error response" do
      json = JsonRpc.encode_error_response(1, -32600, "Invalid Request")
      decoded = Jason.decode!(json)

      assert decoded["jsonrpc"] == "2.0"
      assert decoded["id"] == 1
      assert decoded["error"]["code"] == -32600
      assert decoded["error"]["message"] == "Invalid Request"
      refute Map.has_key?(decoded["error"], "data")
    end

    test "includes data when provided" do
      json = JsonRpc.encode_error_response(1, -32600, "Invalid Request", %{"detail" => "missing field"})
      decoded = Jason.decode!(json)

      assert decoded["error"]["data"] == %{"detail" => "missing field"}
    end

    test "supports nil id for parse errors" do
      json = JsonRpc.encode_error_response(nil, -32700, "Parse error")
      decoded = Jason.decode!(json)

      assert decoded["id"] == nil
    end
  end

  describe "decode/1" do
    test "decodes request" do
      json = ~s({"jsonrpc":"2.0","id":1,"method":"ping"})
      assert {:ok, {:request, msg}} = JsonRpc.decode(json)

      assert msg["id"] == 1
      assert msg["method"] == "ping"
    end

    test "decodes notification" do
      json = ~s({"jsonrpc":"2.0","method":"notifications/initialized"})
      assert {:ok, {:notification, msg}} = JsonRpc.decode(json)

      assert msg["method"] == "notifications/initialized"
      refute Map.has_key?(msg, "id")
    end

    test "decodes success response" do
      json = ~s({"jsonrpc":"2.0","id":1,"result":{"tools":[]}})
      assert {:ok, {:response, msg}} = JsonRpc.decode(json)

      assert msg["id"] == 1
      assert msg["result"] == %{"tools" => []}
    end

    test "decodes error response" do
      json = ~s({"jsonrpc":"2.0","id":1,"error":{"code":-32600,"message":"Invalid"}})
      assert {:ok, {:error_response, msg}} = JsonRpc.decode(json)

      assert msg["id"] == 1
      assert msg["error"]["code"] == -32600
    end

    test "returns parse_error for invalid JSON" do
      assert {:error, :parse_error} = JsonRpc.decode("not json")
    end

    test "returns invalid_message for non-object JSON" do
      assert {:error, :invalid_message} = JsonRpc.decode("[1,2,3]")
    end

    test "returns invalid_message for unrecognized structure" do
      assert {:error, :invalid_message} = JsonRpc.decode(~s({"foo":"bar"}))
    end
  end

  describe "decode!/1" do
    test "returns decoded message on success" do
      json = ~s({"jsonrpc":"2.0","id":1,"result":{}})
      assert {:response, _} = JsonRpc.decode!(json)
    end

    test "raises on invalid input" do
      assert_raise ArgumentError, fn ->
        JsonRpc.decode!("invalid")
      end
    end
  end

  describe "classify_message/1" do
    test "classifies request" do
      msg = %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}
      assert {:ok, {:request, ^msg}} = JsonRpc.classify_message(msg)
    end

    test "classifies notification" do
      msg = %{"jsonrpc" => "2.0", "method" => "notify"}
      assert {:ok, {:notification, ^msg}} = JsonRpc.classify_message(msg)
    end

    test "classifies response" do
      msg = %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}
      assert {:ok, {:response, ^msg}} = JsonRpc.classify_message(msg)
    end

    test "classifies error response" do
      msg = %{"jsonrpc" => "2.0", "id" => 1, "error" => %{"code" => -32600, "message" => "Invalid"}}
      assert {:ok, {:error_response, ^msg}} = JsonRpc.classify_message(msg)
    end
  end

  describe "message_type/1" do
    test "returns correct type" do
      assert :request == JsonRpc.message_type(%{"jsonrpc" => "2.0", "id" => 1, "method" => "x"})
      assert :notification == JsonRpc.message_type(%{"jsonrpc" => "2.0", "method" => "x"})
      assert :response == JsonRpc.message_type(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}})
      assert :error_response == JsonRpc.message_type(%{"jsonrpc" => "2.0", "id" => 1, "error" => %{}})
      assert :unknown == JsonRpc.message_type(%{"foo" => "bar"})
    end
  end

  describe "valid_request?/1" do
    test "returns true for valid request" do
      msg = %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}
      assert JsonRpc.valid_request?(msg)
    end

    test "returns false without jsonrpc version" do
      msg = %{"id" => 1, "method" => "ping"}
      refute JsonRpc.valid_request?(msg)
    end

    test "returns false without id" do
      msg = %{"jsonrpc" => "2.0", "method" => "ping"}
      refute JsonRpc.valid_request?(msg)
    end

    test "returns false without method" do
      msg = %{"jsonrpc" => "2.0", "id" => 1}
      refute JsonRpc.valid_request?(msg)
    end

    test "returns false for non-string method" do
      msg = %{"jsonrpc" => "2.0", "id" => 1, "method" => 123}
      refute JsonRpc.valid_request?(msg)
    end
  end

  describe "valid_notification?/1" do
    test "returns true for valid notification" do
      msg = %{"jsonrpc" => "2.0", "method" => "notify"}
      assert JsonRpc.valid_notification?(msg)
    end

    test "returns false if has id" do
      msg = %{"jsonrpc" => "2.0", "id" => 1, "method" => "notify"}
      refute JsonRpc.valid_notification?(msg)
    end
  end

  describe "valid_response?/1" do
    test "returns true for success response" do
      msg = %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}
      assert JsonRpc.valid_response?(msg)
    end

    test "returns true for error response" do
      msg = %{"jsonrpc" => "2.0", "id" => 1, "error" => %{"code" => -32600, "message" => "err"}}
      assert JsonRpc.valid_response?(msg)
    end

    test "returns false without id" do
      msg = %{"jsonrpc" => "2.0", "result" => %{}}
      refute JsonRpc.valid_response?(msg)
    end
  end

  describe "utility functions" do
    test "get_id/1 returns id" do
      assert 42 == JsonRpc.get_id(%{"id" => 42})
      assert nil == JsonRpc.get_id(%{"method" => "x"})
    end

    test "get_method/1 returns method" do
      assert "ping" == JsonRpc.get_method(%{"method" => "ping"})
      assert nil == JsonRpc.get_method(%{"id" => 1})
    end

    test "get_params/1 returns params" do
      assert %{"x" => 1} == JsonRpc.get_params(%{"params" => %{"x" => 1}})
      assert nil == JsonRpc.get_params(%{"id" => 1})
    end

    test "get_result/1 returns result" do
      assert %{} == JsonRpc.get_result(%{"result" => %{}})
      assert nil == JsonRpc.get_result(%{"error" => %{}})
    end

    test "get_error/1 returns error" do
      error = %{"code" => -32600, "message" => "err"}
      assert ^error = JsonRpc.get_error(%{"error" => error})
      assert nil == JsonRpc.get_error(%{"result" => %{}})
    end

    test "error_response?/1 checks for error" do
      assert JsonRpc.error_response?(%{"error" => %{}})
      refute JsonRpc.error_response?(%{"result" => %{}})
    end
  end
end
