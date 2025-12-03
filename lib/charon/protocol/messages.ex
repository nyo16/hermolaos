defmodule Charon.Protocol.Messages do
  @moduledoc """
  MCP message builders for all protocol methods.

  This module provides functions to build properly formatted MCP request
  and notification messages. Each function returns a map that can be
  sent through a transport.

  ## Protocol Version

  The default protocol version is `2025-03-26`.
  This can be overridden in the `initialize/3` function.

  ## Message Categories

  ### Lifecycle Messages
  - `initialize/3` - Initialize connection
  - `initialized_notification/0` - Confirm initialization complete
  - `ping/0` - Liveness check

  ### Tool Messages
  - `tools_list/1` - List available tools
  - `tools_call/2` - Invoke a tool

  ### Resource Messages
  - `resources_list/1` - List resources
  - `resources_read/1` - Read a resource
  - `resources_subscribe/1` - Subscribe to changes
  - `resources_unsubscribe/1` - Unsubscribe

  ### Prompt Messages
  - `prompts_list/1` - List prompts
  - `prompts_get/2` - Get a prompt

  ### Other Messages
  - `logging_set_level/1` - Set logging level
  - `completion_complete/2` - Request completions
  """

  @default_protocol_version "2025-03-26"

  @doc """
  Returns the default MCP protocol version.
  """
  @spec default_protocol_version() :: String.t()
  def default_protocol_version, do: @default_protocol_version

  # ============================================================================
  # Lifecycle Messages
  # ============================================================================

  @doc """
  Builds an initialize request message.

  This is the first message sent by the client to establish the connection
  and negotiate capabilities.

  ## Parameters

  - `protocol_version` - The protocol version to request
  - `capabilities` - Client capabilities map
  - `client_info` - Client identification info

  ## Examples

      msg = Charon.Protocol.Messages.initialize(
        "2025-03-26",
        %{roots: %{listChanged: true}},
        %{name: "MyClient", version: "1.0.0"}
      )
  """
  @spec initialize(String.t(), map(), map()) :: map()
  def initialize(protocol_version \\ @default_protocol_version, capabilities, client_info) do
    %{
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => protocol_version,
        "capabilities" => normalize_capabilities(capabilities),
        "clientInfo" => client_info
      }
    }
  end

  @doc """
  Builds the initialized notification.

  Sent by the client after receiving a successful initialize response
  to indicate the handshake is complete.

  ## Examples

      msg = Charon.Protocol.Messages.initialized_notification()
      # => %{"method" => "notifications/initialized"}
  """
  @spec initialized_notification() :: map()
  def initialized_notification do
    %{"method" => "notifications/initialized"}
  end

  @doc """
  Builds a ping request.

  Used to check if the connection is alive.

  ## Examples

      msg = Charon.Protocol.Messages.ping()
      # => %{"method" => "ping"}
  """
  @spec ping() :: map()
  def ping do
    %{"method" => "ping"}
  end

  # ============================================================================
  # Tool Messages
  # ============================================================================

  @doc """
  Builds a tools/list request.

  Lists all tools available on the server.

  ## Parameters

  - `cursor` - Optional pagination cursor

  ## Examples

      msg = Charon.Protocol.Messages.tools_list()
      msg = Charon.Protocol.Messages.tools_list("cursor123")
  """
  @spec tools_list(String.t() | nil) :: map()
  def tools_list(cursor \\ nil) do
    params = if cursor, do: %{"cursor" => cursor}, else: %{}
    %{"method" => "tools/list", "params" => params}
  end

  @doc """
  Builds a tools/call request.

  Invokes a tool with the given arguments.

  ## Parameters

  - `name` - Tool name
  - `arguments` - Tool arguments map

  ## Examples

      msg = Charon.Protocol.Messages.tools_call("read_file", %{"path" => "/tmp/test.txt"})
  """
  @spec tools_call(String.t(), map()) :: map()
  def tools_call(name, arguments) when is_binary(name) and is_map(arguments) do
    %{
      "method" => "tools/call",
      "params" => %{
        "name" => name,
        "arguments" => arguments
      }
    }
  end

  # ============================================================================
  # Resource Messages
  # ============================================================================

  @doc """
  Builds a resources/list request.

  Lists all resources available on the server.

  ## Parameters

  - `cursor` - Optional pagination cursor

  ## Examples

      msg = Charon.Protocol.Messages.resources_list()
  """
  @spec resources_list(String.t() | nil) :: map()
  def resources_list(cursor \\ nil) do
    params = if cursor, do: %{"cursor" => cursor}, else: %{}
    %{"method" => "resources/list", "params" => params}
  end

  @doc """
  Builds a resources/templates/list request.

  Lists resource templates available on the server.

  ## Parameters

  - `cursor` - Optional pagination cursor
  """
  @spec resources_templates_list(String.t() | nil) :: map()
  def resources_templates_list(cursor \\ nil) do
    params = if cursor, do: %{"cursor" => cursor}, else: %{}
    %{"method" => "resources/templates/list", "params" => params}
  end

  @doc """
  Builds a resources/read request.

  Reads the content of a specific resource.

  ## Parameters

  - `uri` - Resource URI

  ## Examples

      msg = Charon.Protocol.Messages.resources_read("file:///project/README.md")
  """
  @spec resources_read(String.t()) :: map()
  def resources_read(uri) when is_binary(uri) do
    %{
      "method" => "resources/read",
      "params" => %{"uri" => uri}
    }
  end

  @doc """
  Builds a resources/subscribe request.

  Subscribes to updates for a specific resource.

  ## Parameters

  - `uri` - Resource URI

  ## Examples

      msg = Charon.Protocol.Messages.resources_subscribe("file:///project/src/main.rs")
  """
  @spec resources_subscribe(String.t()) :: map()
  def resources_subscribe(uri) when is_binary(uri) do
    %{
      "method" => "resources/subscribe",
      "params" => %{"uri" => uri}
    }
  end

  @doc """
  Builds a resources/unsubscribe request.

  Unsubscribes from updates for a specific resource.

  ## Parameters

  - `uri` - Resource URI
  """
  @spec resources_unsubscribe(String.t()) :: map()
  def resources_unsubscribe(uri) when is_binary(uri) do
    %{
      "method" => "resources/unsubscribe",
      "params" => %{"uri" => uri}
    }
  end

  # ============================================================================
  # Prompt Messages
  # ============================================================================

  @doc """
  Builds a prompts/list request.

  Lists all prompts available on the server.

  ## Parameters

  - `cursor` - Optional pagination cursor

  ## Examples

      msg = Charon.Protocol.Messages.prompts_list()
  """
  @spec prompts_list(String.t() | nil) :: map()
  def prompts_list(cursor \\ nil) do
    params = if cursor, do: %{"cursor" => cursor}, else: %{}
    %{"method" => "prompts/list", "params" => params}
  end

  @doc """
  Builds a prompts/get request.

  Gets a specific prompt, optionally with argument values.

  ## Parameters

  - `name` - Prompt name
  - `arguments` - Optional argument values

  ## Examples

      msg = Charon.Protocol.Messages.prompts_get("code_review")
      msg = Charon.Protocol.Messages.prompts_get("summarize", %{"language" => "elixir"})
  """
  @spec prompts_get(String.t(), map()) :: map()
  def prompts_get(name, arguments \\ %{}) when is_binary(name) do
    params = %{"name" => name}
    params = if map_size(arguments) > 0, do: Map.put(params, "arguments", arguments), else: params

    %{"method" => "prompts/get", "params" => params}
  end

  # ============================================================================
  # Logging Messages
  # ============================================================================

  @doc """
  Builds a logging/setLevel request.

  Sets the server's logging level.

  ## Parameters

  - `level` - Log level (debug, info, notice, warning, error, critical, alert, emergency)

  ## Examples

      msg = Charon.Protocol.Messages.logging_set_level("debug")
  """
  @spec logging_set_level(String.t()) :: map()
  def logging_set_level(level) when is_binary(level) do
    %{
      "method" => "logging/setLevel",
      "params" => %{"level" => level}
    }
  end

  # ============================================================================
  # Completion Messages
  # ============================================================================

  @doc """
  Builds a completion/complete request.

  Requests argument completion suggestions.

  ## Parameters

  - `ref` - Reference object (prompt or resource)
  - `argument` - Argument to complete

  ## Examples

      msg = Charon.Protocol.Messages.completion_complete(
        %{"type" => "ref/prompt", "name" => "code_review"},
        %{"name" => "language", "value" => "eli"}
      )
  """
  @spec completion_complete(map(), map()) :: map()
  def completion_complete(ref, argument) when is_map(ref) and is_map(argument) do
    %{
      "method" => "completion/complete",
      "params" => %{
        "ref" => ref,
        "argument" => argument
      }
    }
  end

  # ============================================================================
  # Notification Messages
  # ============================================================================

  @doc """
  Builds a cancellation notification.

  Sent to cancel a pending request.

  ## Parameters

  - `request_id` - ID of the request to cancel
  - `reason` - Optional cancellation reason

  ## Examples

      msg = Charon.Protocol.Messages.cancelled_notification(123)
      msg = Charon.Protocol.Messages.cancelled_notification(123, "User cancelled")
  """
  @spec cancelled_notification(integer() | String.t(), String.t() | nil) :: map()
  def cancelled_notification(request_id, reason \\ nil) do
    params = %{"requestId" => request_id}
    params = if reason, do: Map.put(params, "reason", reason), else: params

    %{"method" => "notifications/cancelled", "params" => params}
  end

  @doc """
  Builds a progress notification.

  Sent to report progress on a long-running operation.

  ## Parameters

  - `progress_token` - Token identifying the operation
  - `progress` - Current progress value
  - `total` - Optional total value

  ## Examples

      msg = Charon.Protocol.Messages.progress_notification("op123", 50, 100)
  """
  @spec progress_notification(String.t() | integer(), number(), number() | nil) :: map()
  def progress_notification(progress_token, progress, total \\ nil) do
    params = %{
      "progressToken" => progress_token,
      "progress" => progress
    }

    params = if total, do: Map.put(params, "total", total), else: params

    %{"method" => "notifications/progress", "params" => params}
  end

  @doc """
  Builds a roots/list_changed notification.

  Sent when the client's root list changes.
  """
  @spec roots_list_changed_notification() :: map()
  def roots_list_changed_notification do
    %{"method" => "notifications/roots/list_changed"}
  end

  # ============================================================================
  # Response Builders (for server-to-client requests)
  # ============================================================================

  @doc """
  Builds a response to a ping request.
  """
  @spec ping_response() :: map()
  def ping_response do
    %{}
  end

  @doc """
  Builds a response to a roots/list request.

  ## Parameters

  - `roots` - List of root objects

  ## Examples

      msg = Charon.Protocol.Messages.roots_list_response([
        %{"uri" => "file:///project", "name" => "Project Root"}
      ])
  """
  @spec roots_list_response([map()]) :: map()
  def roots_list_response(roots) when is_list(roots) do
    %{"roots" => roots}
  end

  @doc """
  Builds an error response to a sampling/createMessage request.

  Used when the client doesn't support sampling.
  """
  @spec sampling_not_supported_error() :: map()
  def sampling_not_supported_error do
    %{
      "code" => -32601,
      "message" => "Sampling not supported by this client"
    }
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # Normalize capability keys to strings for JSON encoding
  defp normalize_capabilities(caps) when is_map(caps) do
    Map.new(caps, fn {k, v} ->
      key = if is_atom(k), do: Atom.to_string(k), else: k
      value = if is_map(v), do: normalize_capabilities(v), else: v
      {key, value}
    end)
  end
end
