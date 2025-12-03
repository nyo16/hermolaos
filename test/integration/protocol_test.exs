defmodule Charon.Integration.ProtocolTest do
  @moduledoc """
  Integration tests for MCP protocol handling using mock server.
  """

  use ExUnit.Case, async: true

  alias Charon.Test.MockMCPServer
  alias Charon.Protocol.{JsonRpc, Messages}

  describe "initialize handshake" do
    test "successful initialization" do
      # Create initialize request
      request = Messages.initialize(
        %{name: "TestClient", version: "1.0.0"},
        %{}
      )

      request_json = JsonRpc.encode_request(1, "initialize", request)
      {response_json, state} = MockMCPServer.process(request_json)

      {:ok, {:response, response}} = JsonRpc.decode(response_json)

      assert response["id"] == 1
      assert response["result"]["protocolVersion"]
      assert response["result"]["serverInfo"]["name"] == "MockMCPServer"
      assert response["result"]["capabilities"]
      assert state.initialized == true
    end
  end

  describe "ping" do
    test "ping succeeds" do
      request_json = JsonRpc.encode_request(1, "ping", %{})
      {response_json, _state} = MockMCPServer.process(request_json)

      {:ok, {:response, response}} = JsonRpc.decode(response_json)

      assert response["id"] == 1
      assert response["result"] == %{}
    end
  end

  describe "tools" do
    test "list_tools returns available tools" do
      request_json = JsonRpc.encode_request(1, "tools/list", %{})
      {response_json, _state} = MockMCPServer.process(request_json)

      {:ok, {:response, response}} = JsonRpc.decode(response_json)

      assert response["id"] == 1
      tools = response["result"]["tools"]
      assert length(tools) == 2

      tool_names = Enum.map(tools, & &1["name"])
      assert "echo" in tool_names
      assert "add" in tool_names
    end

    test "call_tool executes echo tool" do
      %{"params" => params} = Messages.tools_call("echo", %{"message" => "hello world"})
      request_json = JsonRpc.encode_request(1, "tools/call", params)
      {response_json, _state} = MockMCPServer.process(request_json)

      {:ok, {:response, response}} = JsonRpc.decode(response_json)

      assert response["id"] == 1
      [content] = response["result"]["content"]
      assert content["type"] == "text"
      assert content["text"] == "Echo: hello world"
    end

    test "call_tool executes add tool" do
      %{"params" => params} = Messages.tools_call("add", %{"a" => 5, "b" => 3})
      request_json = JsonRpc.encode_request(1, "tools/call", params)
      {response_json, _state} = MockMCPServer.process(request_json)

      {:ok, {:response, response}} = JsonRpc.decode(response_json)

      [content] = response["result"]["content"]
      assert content["text"] == "8"
    end

    test "call_tool returns error for unknown tool" do
      %{"params" => params} = Messages.tools_call("nonexistent", %{})
      request_json = JsonRpc.encode_request(1, "tools/call", params)
      {response_json, _state} = MockMCPServer.process(request_json)

      {:ok, {:error_response, response}} = JsonRpc.decode(response_json)

      assert response["id"] == 1
      assert response["error"]["code"] == -32602
      assert response["error"]["message"] =~ "Unknown tool"
    end
  end

  describe "resources" do
    test "list_resources returns available resources" do
      request_json = JsonRpc.encode_request(1, "resources/list", %{})
      {response_json, _state} = MockMCPServer.process(request_json)

      {:ok, {:response, response}} = JsonRpc.decode(response_json)

      resources = response["result"]["resources"]
      assert length(resources) == 2

      uris = Enum.map(resources, & &1["uri"])
      assert "file:///test/document.txt" in uris
      assert "file:///test/data.json" in uris
    end

    test "read_resource returns resource content" do
      %{"params" => params} = Messages.resources_read("file:///test/document.txt")
      request_json = JsonRpc.encode_request(1, "resources/read", params)
      {response_json, _state} = MockMCPServer.process(request_json)

      {:ok, {:response, response}} = JsonRpc.decode(response_json)

      [content] = response["result"]["contents"]
      assert content["uri"] == "file:///test/document.txt"
      assert content["mimeType"] == "text/plain"
      assert content["text"] =~ "Mock content"
    end

    test "read_resource returns error for unknown resource" do
      %{"params" => params} = Messages.resources_read("file:///nonexistent")
      request_json = JsonRpc.encode_request(1, "resources/read", params)
      {response_json, _state} = MockMCPServer.process(request_json)

      {:ok, {:error_response, response}} = JsonRpc.decode(response_json)

      assert response["error"]["code"] == -32002
      assert response["error"]["message"] =~ "Resource not found"
    end
  end

  describe "prompts" do
    test "list_prompts returns available prompts" do
      request_json = JsonRpc.encode_request(1, "prompts/list", %{})
      {response_json, _state} = MockMCPServer.process(request_json)

      {:ok, {:response, response}} = JsonRpc.decode(response_json)

      prompts = response["result"]["prompts"]
      assert length(prompts) == 2

      names = Enum.map(prompts, & &1["name"])
      assert "greeting" in names
      assert "summarize" in names
    end

    test "get_prompt returns prompt messages" do
      %{"params" => params} = Messages.prompts_get("greeting", %{"name" => "Alice"})
      request_json = JsonRpc.encode_request(1, "prompts/get", params)
      {response_json, _state} = MockMCPServer.process(request_json)

      {:ok, {:response, response}} = JsonRpc.decode(response_json)

      messages = response["result"]["messages"]
      assert length(messages) == 1

      [message] = messages
      assert message["role"] == "user"
      assert message["content"]["type"] == "text"
      assert message["content"]["text"] =~ "greeting"
      assert message["content"]["text"] =~ "Alice"
    end

    test "get_prompt returns error for unknown prompt" do
      %{"params" => params} = Messages.prompts_get("nonexistent", %{})
      request_json = JsonRpc.encode_request(1, "prompts/get", params)
      {response_json, _state} = MockMCPServer.process(request_json)

      {:ok, {:error_response, response}} = JsonRpc.decode(response_json)

      assert response["error"]["code"] == -32602
      assert response["error"]["message"] =~ "Unknown prompt"
    end
  end

  describe "logging" do
    test "setLevel succeeds" do
      request_json = JsonRpc.encode_request(1, "logging/setLevel", %{"level" => "debug"})
      {response_json, _state} = MockMCPServer.process(request_json)

      {:ok, {:response, response}} = JsonRpc.decode(response_json)

      assert response["id"] == 1
      assert response["result"] == %{}
    end
  end

  describe "error handling" do
    test "returns parse error for invalid JSON" do
      {response_json, _state} = MockMCPServer.process("not valid json")

      {:ok, {:error_response, response}} = JsonRpc.decode(response_json)

      assert response["error"]["code"] == -32700
      assert response["error"]["message"] == "Parse error"
    end

    test "returns method not found for unknown method" do
      request_json = JsonRpc.encode_request(1, "unknown/method", %{})
      {response_json, _state} = MockMCPServer.process(request_json)

      {:ok, {:error_response, response}} = JsonRpc.decode(response_json)

      assert response["error"]["code"] == -32601
      assert response["error"]["message"] =~ "Method not found"
    end
  end

  describe "notifications" do
    test "notifications do not produce responses" do
      notification_json = JsonRpc.encode_notification("notifications/initialized", %{})
      {response, _state} = MockMCPServer.process(notification_json)

      assert response == nil
    end
  end

  describe "request ID handling" do
    test "response ID matches request ID" do
      for id <- [1, 42, 999, "abc", "request-123"] do
        request_json = JsonRpc.encode_request(id, "ping", %{})
        {response_json, _state} = MockMCPServer.process(request_json)

        {:ok, {:response, response}} = JsonRpc.decode(response_json)
        assert response["id"] == id
      end
    end
  end

  describe "state persistence" do
    test "state carries across requests" do
      state = MockMCPServer.default_state()

      # First initialize
      request1 = JsonRpc.encode_request(1, "initialize", Messages.initialize(
        %{name: "Test", version: "1.0.0"},
        %{}
      ))
      {_response1, state} = MockMCPServer.process(request1, state)
      assert state.initialized == true

      # Then list tools (state persists)
      request2 = JsonRpc.encode_request(2, "tools/list", %{})
      {response2, _state} = MockMCPServer.process(request2, state)

      {:ok, {:response, response}} = JsonRpc.decode(response2)
      assert response["id"] == 2
      assert length(response["result"]["tools"]) == 2
    end
  end
end
