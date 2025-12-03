defmodule Hermolaos.Test.MockMCPServer do
  @moduledoc """
  A mock MCP server for integration testing.

  This server can be started in stdio mode (for testing stdio transport)
  or called directly from tests for simple protocol testing.
  """

  alias Hermolaos.Protocol.JsonRpc

  @default_capabilities %{
    "tools" => %{},
    "resources" => %{},
    "prompts" => %{}
  }

  @default_server_info %{
    "name" => "MockMCPServer",
    "version" => "1.0.0"
  }

  @doc """
  Processes a JSON-RPC request and returns a response.

  This can be used to test protocol handling without actual I/O.
  """
  def process(request_json, state \\ default_state()) when is_binary(request_json) do
    case JsonRpc.decode(request_json) do
      {:ok, {type, message}} ->
        handle_message(type, message, state)

      {:error, :parse_error} ->
        response = JsonRpc.encode_error_response(nil, -32700, "Parse error")
        {response, state}

      {:error, :invalid_message} ->
        response = JsonRpc.encode_error_response(nil, -32600, "Invalid Request")
        {response, state}
    end
  end

  @doc """
  Returns default server state.
  """
  def default_state do
    %{
      initialized: false,
      tools: default_tools(),
      resources: default_resources(),
      prompts: default_prompts()
    }
  end

  # Handle different message types
  defp handle_message(:request, message, state) do
    id = message["id"]
    method = message["method"]
    params = message["params"] || %{}

    {result, new_state} = handle_request(method, params, state)

    response =
      case result do
        {:ok, result_data} ->
          JsonRpc.encode_response(id, result_data)

        {:error, {code, msg}} ->
          JsonRpc.encode_error_response(id, code, msg)
      end

    {response, new_state}
  end

  defp handle_message(:notification, _message, state) do
    # Notifications don't get responses
    {nil, state}
  end

  defp handle_message(_type, message, state) do
    id = message["id"]
    response = JsonRpc.encode_error_response(id, -32600, "Invalid Request")
    {response, state}
  end

  # Request handlers
  defp handle_request("initialize", params, state) do
    _client_info = params["clientInfo"]
    _capabilities = params["capabilities"]

    result = %{
      "protocolVersion" => params["protocolVersion"] || "2025-03-26",
      "capabilities" => @default_capabilities,
      "serverInfo" => @default_server_info
    }

    {{:ok, result}, %{state | initialized: true}}
  end

  defp handle_request("ping", _params, state) do
    {{:ok, %{}}, state}
  end

  defp handle_request("tools/list", _params, state) do
    result = %{"tools" => state.tools}
    {{:ok, result}, state}
  end

  defp handle_request("tools/call", params, state) do
    name = params["name"]
    arguments = params["arguments"] || %{}

    case find_tool(state.tools, name) do
      nil ->
        {{:error, {-32602, "Unknown tool: #{name}"}}, state}

      _tool ->
        # Simulate tool execution
        result = simulate_tool_call(name, arguments)
        {{:ok, result}, state}
    end
  end

  defp handle_request("resources/list", _params, state) do
    result = %{"resources" => state.resources}
    {{:ok, result}, state}
  end

  defp handle_request("resources/read", params, state) do
    uri = params["uri"]

    case find_resource(state.resources, uri) do
      nil ->
        {{:error, {-32002, "Resource not found: #{uri}"}}, state}

      resource ->
        result = %{
          "contents" => [
            %{
              "uri" => uri,
              "mimeType" => resource["mimeType"] || "text/plain",
              "text" => "Mock content for #{uri}"
            }
          ]
        }

        {{:ok, result}, state}
    end
  end

  defp handle_request("prompts/list", _params, state) do
    result = %{"prompts" => state.prompts}
    {{:ok, result}, state}
  end

  defp handle_request("prompts/get", params, state) do
    name = params["name"]
    arguments = params["arguments"] || %{}

    case find_prompt(state.prompts, name) do
      nil ->
        {{:error, {-32602, "Unknown prompt: #{name}"}}, state}

      prompt ->
        result = %{
          "description" => prompt["description"],
          "messages" => [
            %{
              "role" => "user",
              "content" => %{
                "type" => "text",
                "text" => "Prompt: #{name} with args: #{inspect(arguments)}"
              }
            }
          ]
        }

        {{:ok, result}, state}
    end
  end

  defp handle_request("logging/setLevel", params, state) do
    _level = params["level"]
    {{:ok, %{}}, state}
  end

  defp handle_request(method, _params, state) do
    {{:error, {-32601, "Method not found: #{method}"}}, state}
  end

  # Helper functions
  defp find_tool(tools, name) do
    Enum.find(tools, fn t -> t["name"] == name end)
  end

  defp find_resource(resources, uri) do
    Enum.find(resources, fn r -> r["uri"] == uri end)
  end

  defp find_prompt(prompts, name) do
    Enum.find(prompts, fn p -> p["name"] == name end)
  end

  defp simulate_tool_call("echo", args) do
    %{
      "content" => [
        %{
          "type" => "text",
          "text" => "Echo: #{args["message"] || ""}"
        }
      ]
    }
  end

  defp simulate_tool_call("add", args) do
    a = args["a"] || 0
    b = args["b"] || 0

    %{
      "content" => [
        %{
          "type" => "text",
          "text" => "#{a + b}"
        }
      ]
    }
  end

  defp simulate_tool_call(_name, _args) do
    %{
      "content" => [
        %{
          "type" => "text",
          "text" => "Tool executed successfully"
        }
      ]
    }
  end

  # Default data
  defp default_tools do
    [
      %{
        "name" => "echo",
        "description" => "Echoes back the input message",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "message" => %{"type" => "string", "description" => "Message to echo"}
          },
          "required" => ["message"]
        }
      },
      %{
        "name" => "add",
        "description" => "Adds two numbers",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "a" => %{"type" => "number", "description" => "First number"},
            "b" => %{"type" => "number", "description" => "Second number"}
          },
          "required" => ["a", "b"]
        }
      }
    ]
  end

  defp default_resources do
    [
      %{
        "uri" => "file:///test/document.txt",
        "name" => "Test Document",
        "description" => "A test document for testing",
        "mimeType" => "text/plain"
      },
      %{
        "uri" => "file:///test/data.json",
        "name" => "Test Data",
        "description" => "Test JSON data",
        "mimeType" => "application/json"
      }
    ]
  end

  defp default_prompts do
    [
      %{
        "name" => "greeting",
        "description" => "A simple greeting prompt",
        "arguments" => [
          %{
            "name" => "name",
            "description" => "Name to greet",
            "required" => true
          }
        ]
      },
      %{
        "name" => "summarize",
        "description" => "Summarize text",
        "arguments" => [
          %{
            "name" => "text",
            "description" => "Text to summarize",
            "required" => true
          }
        ]
      }
    ]
  end
end
