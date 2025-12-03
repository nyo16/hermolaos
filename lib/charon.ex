defmodule Charon do
  @moduledoc """
  MCP (Model Context Protocol) client for Elixir.

  Charon provides a complete implementation of the Model Context Protocol,
  enabling Elixir applications to connect to MCP servers and access their
  tools, resources, and prompts.

  ## Quick Start

      # Connect to a local MCP server via stdio
      {:ok, client} = Charon.connect(:stdio,
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
      )

      # List available tools
      {:ok, tools} = Charon.list_tools(client)

      # Call a tool
      {:ok, result} = Charon.call_tool(client, "read_file", %{"path" => "/tmp/test.txt"})

      # Disconnect when done
      :ok = Charon.disconnect(client)

  ## Transports

  Charon supports two transport mechanisms:

  ### Stdio Transport

  Launches an MCP server as a subprocess and communicates via stdin/stdout.

      {:ok, client} = Charon.connect(:stdio,
        command: "/path/to/server",
        args: ["--arg1", "value"],
        env: [{"DEBUG", "1"}]
      )

  ### HTTP Transport

  Connects to a remote MCP server via HTTP/SSE.

      {:ok, client} = Charon.connect(:http,
        url: "http://localhost:3000/mcp",
        headers: [{"authorization", "Bearer token"}]
      )

  ## Error Handling

  All operations return `{:ok, result}` or `{:error, reason}`. Errors
  are typically `Charon.Protocol.Errors` structs with error codes.

      case Charon.call_tool(client, "unknown_tool", %{}) do
        {:ok, result} -> handle_result(result)
        {:error, %Charon.Protocol.Errors{code: -32601}} -> IO.puts("Tool not found")
        {:error, reason} -> IO.puts("Error: \#{inspect(reason)}")
      end

  ## Notification Handling

  To receive server notifications, configure a notification handler:

      defmodule MyHandler do
        @behaviour Charon.Client.NotificationHandler

        @impl true
        def handle_notification({:notification, method, params}, state) do
          IO.puts("Got notification: \#{method}")
          {:ok, state}
        end
      end

      {:ok, client} = Charon.connect(:stdio,
        command: "my-server",
        notification_handler: {MyHandler, %{}}
      )
  """

  alias Charon.Client.Connection
  alias Charon.Protocol.Messages

  @type client :: Connection.t()
  @type transport :: :stdio | :http

  # ============================================================================
  # Response Normalization
  # ============================================================================

  # Converts string keys to atoms for more ergonomic pattern matching
  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_atom(k), atomize_keys(v)}
      {k, v} -> {k, atomize_keys(v)}
    end)
  end

  defp atomize_keys(list) when is_list(list) do
    Enum.map(list, &atomize_keys/1)
  end

  defp atomize_keys(other), do: other

  defp normalize_response({:ok, result}), do: {:ok, atomize_keys(result)}
  defp normalize_response(error), do: error

  # ============================================================================
  # Connection Management
  # ============================================================================

  @doc """
  Connects to an MCP server.

  ## Parameters

  - `transport` - Either `:stdio` or `:http`
  - `opts` - Transport-specific options

  ## Stdio Options

  - `:command` - Command to execute (required)
  - `:args` - Command arguments (default: `[]`)
  - `:env` - Environment variables as `[{name, value}]` (default: `[]`)
  - `:cd` - Working directory (optional)

  ## HTTP Options

  - `:url` - Server endpoint URL (required)
  - `:headers` - Additional HTTP headers (default: `[]`)
  - `:req_options` - Options passed to Req (default: `[]`)

  ## Common Options

  - `:client_info` - Client identification map (default: Charon info)
  - `:capabilities` - Client capabilities (default: standard)
  - `:notification_handler` - Module or `{module, state}` for notifications
  - `:timeout` - Default request timeout in ms (default: 30000)
  - `:name` - GenServer name (optional)

  ## Examples

      # Stdio with npx
      {:ok, client} = Charon.connect(:stdio,
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
      )

      # HTTP with authentication
      {:ok, client} = Charon.connect(:http,
        url: "https://api.example.com/mcp",
        headers: [{"authorization", "Bearer token123"}]
      )

      # Named connection
      {:ok, _} = Charon.connect(:stdio,
        command: "my-server",
        name: MyApp.MCPClient
      )
      # Later: Charon.list_tools(MyApp.MCPClient)
  """
  @spec connect(transport(), keyword()) :: {:ok, client()} | {:error, term()}
  def connect(transport, opts \\ [])

  def connect(:stdio, opts) do
    opts = Keyword.put(opts, :transport, :stdio)
    Connection.start_link(opts)
  end

  def connect(:http, opts) do
    opts = Keyword.put(opts, :transport, :http)
    Connection.start_link(opts)
  end

  @doc """
  Disconnects from the MCP server.

  This gracefully closes the connection, cleaning up resources.

  ## Examples

      :ok = Charon.disconnect(client)
  """
  @spec disconnect(client()) :: :ok
  def disconnect(client) do
    Connection.disconnect(client)
  end

  @doc """
  Gets the current connection status.

  ## Returns

  - `:disconnected` - Not connected
  - `:connecting` - Transport starting
  - `:initializing` - MCP handshake in progress
  - `:ready` - Ready for requests

  ## Examples

      :ready = Charon.status(client)
  """
  @spec status(client()) :: Connection.status()
  def status(client) do
    Connection.status(client)
  end

  @doc """
  Gets server information from the initialization response.

  ## Examples

      {:ok, %{"name" => "MyServer", "version" => "1.0.0"}} = Charon.server_info(client)
  """
  @spec server_info(client()) :: {:ok, map()} | {:error, :not_initialized}
  def server_info(client) do
    Connection.server_info(client)
  end

  @doc """
  Gets server capabilities from the initialization response.

  ## Examples

      {:ok, caps} = Charon.server_capabilities(client)
      if Charon.Protocol.Capabilities.supports?(caps, :tools) do
        # Server supports tools
      end
  """
  @spec server_capabilities(client()) :: {:ok, map()} | {:error, :not_initialized}
  def server_capabilities(client) do
    Connection.server_capabilities(client)
  end

  # ============================================================================
  # Tools
  # ============================================================================

  @doc """
  Lists available tools on the server.

  ## Options

  - `:cursor` - Pagination cursor for subsequent requests
  - `:timeout` - Request timeout override

  ## Returns

  - `{:ok, %{tools: [...], nextCursor: ...}}` - Success (atom keys)
  - `{:error, reason}` - Error

  ## Examples

      {:ok, %{tools: tools}} = Charon.list_tools(client)
      for tool <- tools do
        IO.puts("Tool: \#{tool.name} - \#{tool.description}")
      end
  """
  @spec list_tools(client(), keyword()) :: {:ok, map()} | {:error, term()}
  def list_tools(client, opts \\ []) do
    cursor = Keyword.get(opts, :cursor)
    msg = Messages.tools_list(cursor)

    client
    |> Connection.request(msg["method"], msg["params"], opts)
    |> normalize_response()
  end

  @doc """
  Calls a tool with the given arguments.

  ## Parameters

  - `client` - The MCP client
  - `name` - Tool name
  - `arguments` - Tool arguments map
  - `opts` - Options:
    - `:timeout` - Request timeout override

  ## Returns

  - `{:ok, %{content: [...], isError: false}}` - Success (atom keys)
  - `{:ok, %{content: [...], isError: true}}` - Tool error
  - `{:error, reason}` - Protocol error

  ## Examples

      {:ok, result} = Charon.call_tool(client, "read_file", %{"path" => "/tmp/test.txt"})

      case result do
        %{isError: false, content: content} ->
          for item <- content do
            case item do
              %{type: "text", text: text} -> IO.puts(text)
              %{type: "image", data: data} -> File.write!("image.png", Base.decode64!(data))
            end
          end

        %{isError: true, content: content} ->
          IO.puts("Tool error: \#{inspect(content)}")
      end
  """
  @spec call_tool(client(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def call_tool(client, name, arguments, opts \\ []) do
    msg = Messages.tools_call(name, arguments)

    client
    |> Connection.request(msg["method"], msg["params"], opts)
    |> normalize_response()
  end

  # ============================================================================
  # Resources
  # ============================================================================

  @doc """
  Lists available resources on the server.

  ## Options

  - `:cursor` - Pagination cursor
  - `:timeout` - Request timeout override

  ## Examples

      {:ok, %{resources: resources}} = Charon.list_resources(client)
  """
  @spec list_resources(client(), keyword()) :: {:ok, map()} | {:error, term()}
  def list_resources(client, opts \\ []) do
    cursor = Keyword.get(opts, :cursor)
    msg = Messages.resources_list(cursor)

    client
    |> Connection.request(msg["method"], msg["params"], opts)
    |> normalize_response()
  end

  @doc """
  Lists resource templates on the server.

  ## Options

  - `:cursor` - Pagination cursor
  - `:timeout` - Request timeout override

  ## Examples

      {:ok, %{resourceTemplates: templates}} = Charon.list_resource_templates(client)
  """
  @spec list_resource_templates(client(), keyword()) :: {:ok, map()} | {:error, term()}
  def list_resource_templates(client, opts \\ []) do
    cursor = Keyword.get(opts, :cursor)
    msg = Messages.resources_templates_list(cursor)

    client
    |> Connection.request(msg["method"], msg["params"], opts)
    |> normalize_response()
  end

  @doc """
  Reads a resource by URI.

  ## Parameters

  - `client` - The MCP client
  - `uri` - Resource URI
  - `opts` - Options

  ## Returns

  - `{:ok, %{contents: [...]}}` - Success (atom keys)

  ## Examples

      {:ok, %{contents: contents}} = Charon.read_resource(client, "file:///project/README.md")
      for content <- contents do
        IO.puts(content.text)
      end
  """
  @spec read_resource(client(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def read_resource(client, uri, opts \\ []) do
    msg = Messages.resources_read(uri)

    client
    |> Connection.request(msg["method"], msg["params"], opts)
    |> normalize_response()
  end

  @doc """
  Subscribes to resource updates.

  Requires server to support resource subscriptions.

  ## Examples

      :ok = Charon.subscribe_resource(client, "file:///project/src/main.rs")
  """
  @spec subscribe_resource(client(), String.t()) :: {:ok, map()} | {:error, term()}
  def subscribe_resource(client, uri) do
    msg = Messages.resources_subscribe(uri)

    client
    |> Connection.request(msg["method"], msg["params"])
    |> normalize_response()
  end

  @doc """
  Unsubscribes from resource updates.

  ## Examples

      :ok = Charon.unsubscribe_resource(client, "file:///project/src/main.rs")
  """
  @spec unsubscribe_resource(client(), String.t()) :: {:ok, map()} | {:error, term()}
  def unsubscribe_resource(client, uri) do
    msg = Messages.resources_unsubscribe(uri)

    client
    |> Connection.request(msg["method"], msg["params"])
    |> normalize_response()
  end

  # ============================================================================
  # Prompts
  # ============================================================================

  @doc """
  Lists available prompts on the server.

  ## Options

  - `:cursor` - Pagination cursor
  - `:timeout` - Request timeout override

  ## Examples

      {:ok, %{prompts: prompts}} = Charon.list_prompts(client)
  """
  @spec list_prompts(client(), keyword()) :: {:ok, map()} | {:error, term()}
  def list_prompts(client, opts \\ []) do
    cursor = Keyword.get(opts, :cursor)
    msg = Messages.prompts_list(cursor)

    client
    |> Connection.request(msg["method"], msg["params"], opts)
    |> normalize_response()
  end

  @doc """
  Gets a prompt by name, optionally with argument values.

  ## Parameters

  - `client` - The MCP client
  - `name` - Prompt name
  - `arguments` - Argument values map (default: `%{}`)
  - `opts` - Options

  ## Examples

      {:ok, prompt} = Charon.get_prompt(client, "code_review")
      {:ok, prompt} = Charon.get_prompt(client, "summarize", %{"language" => "elixir"})
  """
  @spec get_prompt(client(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_prompt(client, name, arguments \\ %{}, opts \\ []) do
    msg = Messages.prompts_get(name, arguments)

    client
    |> Connection.request(msg["method"], msg["params"], opts)
    |> normalize_response()
  end

  # ============================================================================
  # Utilities
  # ============================================================================

  @doc """
  Sends a ping to check server liveness.

  ## Examples

      {:ok, %{}} = Charon.ping(client)
  """
  @spec ping(client(), keyword()) :: {:ok, map()} | {:error, term()}
  def ping(client, opts \\ []) do
    msg = Messages.ping()

    client
    |> Connection.request(msg["method"], %{}, opts)
    |> normalize_response()
  end

  @doc """
  Sets the server's logging level.

  ## Parameters

  - `client` - The MCP client
  - `level` - Log level (debug, info, notice, warning, error, critical, alert, emergency)

  ## Examples

      {:ok, _} = Charon.set_log_level(client, "debug")
  """
  @spec set_log_level(client(), String.t()) :: {:ok, map()} | {:error, term()}
  def set_log_level(client, level) do
    msg = Messages.logging_set_level(level)

    client
    |> Connection.request(msg["method"], msg["params"])
    |> normalize_response()
  end

  @doc """
  Requests argument completion suggestions.

  ## Parameters

  - `client` - The MCP client
  - `ref` - Reference object (prompt or resource)
  - `argument` - Argument to complete

  ## Examples

      ref = %{"type" => "ref/prompt", "name" => "code_review"}
      argument = %{"name" => "language", "value" => "eli"}
      {:ok, completions} = Charon.complete(client, ref, argument)
  """
  @spec complete(client(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def complete(client, ref, argument, opts \\ []) do
    msg = Messages.completion_complete(ref, argument)

    client
    |> Connection.request(msg["method"], msg["params"], opts)
    |> normalize_response()
  end

  # ============================================================================
  # Content Helpers
  # ============================================================================

  @doc """
  Extracts text content from a tool call result.

  Tool results contain a list of content items. This helper extracts
  all text items and concatenates them.

  ## Examples

      {:ok, result} = Charon.call_tool(client, "browser_snapshot", %{})
      text = Charon.get_text(result)
  """
  @spec get_text(map()) :: String.t() | nil
  def get_text(%{content: content}) when is_list(content) do
    content
    |> Enum.filter(&(&1.type == "text"))
    |> Enum.map(& &1.text)
    |> Enum.join("\n")
    |> case do
      "" -> nil
      text -> text
    end
  end

  def get_text(_), do: nil

  @doc """
  Extracts image data from a tool call result.

  Returns the base64-decoded binary image data.

  ## Examples

      {:ok, result} = Charon.call_tool(client, "browser_take_screenshot", %{})
      case Charon.get_image(result) do
        {:ok, image_data} -> File.write!("screenshot.png", image_data)
        :error -> IO.puts("No image in response")
      end
  """
  @spec get_image(map()) :: {:ok, binary()} | :error
  def get_image(%{content: content}) when is_list(content) do
    case Enum.find(content, &(&1.type == "image")) do
      %{data: base64_data} ->
        case Base.decode64(base64_data) do
          {:ok, data} -> {:ok, data}
          :error -> :error
        end

      nil ->
        :error
    end
  end

  def get_image(_), do: :error

  @doc """
  Extracts all images from a tool call result.

  Returns a list of base64-decoded binary image data.

  ## Examples

      {:ok, result} = Charon.call_tool(client, "get_images", %{})
      images = Charon.get_images(result)
      Enum.with_index(images, fn data, i ->
        File.write!("image_\#{i}.png", data)
      end)
  """
  @spec get_images(map()) :: [binary()]
  def get_images(%{content: content}) when is_list(content) do
    content
    |> Enum.filter(&(&1.type == "image"))
    |> Enum.map(& &1.data)
    |> Enum.map(&Base.decode64!/1)
  end

  def get_images(_), do: []

  # ============================================================================
  # Notifications
  # ============================================================================

  @doc """
  Sends a cancellation notification for a pending request.

  ## Examples

      :ok = Charon.cancel(client, request_id)
  """
  @spec cancel(client(), integer() | String.t(), String.t() | nil) :: :ok | {:error, term()}
  def cancel(client, request_id, reason \\ nil) do
    msg = Messages.cancelled_notification(request_id, reason)
    Connection.notify(client, msg["method"], msg["params"])
  end
end
