defmodule Charon.Client.Connection do
  @moduledoc """
  GenServer managing a single MCP connection.

  The Connection is the core component of the Charon client. It manages:

  - Transport lifecycle (stdio or HTTP)
  - Protocol initialization handshake
  - Request/response correlation
  - Server notification handling
  - Connection state machine

  ## State Machine

  ```
  :disconnected --> :connecting --> :initializing --> :ready
        ^              |                |               |
        |              v                v               v
        +------------- (error) --------+---------------+
  ```

  ## Usage

  Typically, you don't interact with Connection directly. Use the
  `Charon` module for a higher-level API.

  ## Example

      {:ok, conn} = Charon.Client.Connection.start_link(
        transport: :stdio,
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
      )

      {:ok, tools} = Charon.Client.Connection.request(conn, "tools/list", %{})
  """

  use GenServer
  require Logger

  alias Charon.Client.RequestTracker
  alias Charon.Protocol.{JsonRpc, Messages, Capabilities, Errors}
  alias Charon.Transport.{Stdio, Http}

  # ============================================================================
  # Type Definitions
  # ============================================================================

  @type t :: GenServer.server()

  @type status :: :disconnected | :connecting | :initializing | :ready

  @type transport_type :: :stdio | :http

  @type option ::
          {:transport, transport_type()}
          | {:command, String.t()}
          | {:args, [String.t()]}
          | {:url, String.t()}
          | {:headers, [{String.t(), String.t()}]}
          | {:client_info, map()}
          | {:capabilities, map()}
          | {:notification_handler, module() | {module(), term()}}
          | {:timeout, pos_integer()}
          | {:name, GenServer.name()}

  @type state :: %{
          status: status(),
          transport_type: transport_type(),
          transport_mod: module(),
          transport_pid: pid() | nil,
          transport_opts: keyword(),
          tracker_pid: pid() | nil,
          server_info: map() | nil,
          server_capabilities: map() | nil,
          client_capabilities: map(),
          client_info: map(),
          protocol_version: String.t() | nil,
          notification_handler: module() | {module(), term()} | nil,
          pending_init: GenServer.from() | nil,
          default_timeout: pos_integer()
        }

  @default_timeout 30_000
  @init_timeout 60_000

  @client_info %{
    "name" => "Charon",
    "version" => "0.1.0"
  }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Starts a new MCP connection.

  ## Options

  ### Transport Options (one required)

  For stdio transport:
  - `:transport` - Set to `:stdio`
  - `:command` - Command to execute (required)
  - `:args` - Command arguments (default: [])

  For HTTP transport:
  - `:transport` - Set to `:http`
  - `:url` - Server URL (required)
  - `:headers` - Additional HTTP headers (default: [])

  ### Common Options

  - `:client_info` - Client identification (default: Charon info)
  - `:capabilities` - Client capabilities (default: standard capabilities)
  - `:notification_handler` - Module or `{module, state}` for handling notifications
  - `:timeout` - Default request timeout in ms (default: 30000)
  - `:name` - GenServer name (optional)

  ## Examples

      # Stdio transport
      {:ok, conn} = Charon.Client.Connection.start_link(
        transport: :stdio,
        command: "/usr/bin/python3",
        args: ["-m", "my_mcp_server"]
      )

      # HTTP transport
      {:ok, conn} = Charon.Client.Connection.start_link(
        transport: :http,
        url: "http://localhost:3000/mcp"
      )
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Gets the current connection status.

  ## Returns

  - `:disconnected` - Not connected
  - `:connecting` - Transport starting
  - `:initializing` - Performing MCP handshake
  - `:ready` - Ready for requests
  """
  @spec status(t()) :: status()
  def status(conn) do
    GenServer.call(conn, :status)
  end

  @doc """
  Sends a request and waits for a response.

  ## Parameters

  - `conn` - The connection process
  - `method` - JSON-RPC method name
  - `params` - Request parameters
  - `opts` - Options:
    - `:timeout` - Override default timeout

  ## Returns

  - `{:ok, result}` - Success with result map
  - `{:error, reason}` - Error occurred

  ## Examples

      {:ok, %{"tools" => tools}} = Charon.Client.Connection.request(conn, "tools/list", %{})
  """
  @spec request(t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def request(conn, method, params, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, :infinity)
    GenServer.call(conn, {:request, method, params, opts}, timeout)
  end

  @doc """
  Sends a notification (no response expected).

  ## Parameters

  - `conn` - The connection process
  - `method` - JSON-RPC method name
  - `params` - Notification parameters

  ## Examples

      :ok = Charon.Client.Connection.notify(conn, "notifications/cancelled", %{requestId: 1})
  """
  @spec notify(t(), String.t(), map()) :: :ok | {:error, term()}
  def notify(conn, method, params) do
    GenServer.call(conn, {:notify, method, params})
  end

  @doc """
  Gets server information from the initialization response.
  """
  @spec server_info(t()) :: {:ok, map()} | {:error, :not_initialized}
  def server_info(conn) do
    GenServer.call(conn, :server_info)
  end

  @doc """
  Gets server capabilities from the initialization response.
  """
  @spec server_capabilities(t()) :: {:ok, map()} | {:error, :not_initialized}
  def server_capabilities(conn) do
    GenServer.call(conn, :server_capabilities)
  end

  @doc """
  Disconnects from the server.
  """
  @spec disconnect(t()) :: :ok
  def disconnect(conn) do
    GenServer.stop(conn, :normal)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl GenServer
  def init(opts) do
    transport_type = Keyword.fetch!(opts, :transport)
    transport_mod = transport_module(transport_type)
    transport_opts = build_transport_opts(transport_type, opts)

    client_info = Keyword.get(opts, :client_info, @client_info)
    capabilities = Keyword.get(opts, :capabilities, Capabilities.default_client_capabilities())
    notification_handler = Keyword.get(opts, :notification_handler)
    default_timeout = Keyword.get(opts, :timeout, @default_timeout)

    # Start request tracker
    {:ok, tracker_pid} = RequestTracker.start_link(timeout: default_timeout)

    state = %{
      status: :disconnected,
      transport_type: transport_type,
      transport_mod: transport_mod,
      transport_pid: nil,
      transport_opts: transport_opts,
      tracker_pid: tracker_pid,
      server_info: nil,
      server_capabilities: nil,
      client_capabilities: capabilities,
      client_info: client_info,
      protocol_version: nil,
      notification_handler: notification_handler,
      pending_init: nil,
      default_timeout: default_timeout
    }

    # Auto-connect on start
    send(self(), :connect)

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  @impl GenServer
  def handle_call(:server_info, _from, %{status: :ready, server_info: info} = state) do
    {:reply, {:ok, info}, state}
  end

  def handle_call(:server_info, _from, state) do
    {:reply, {:error, :not_initialized}, state}
  end

  @impl GenServer
  def handle_call(:server_capabilities, _from, %{status: :ready, server_capabilities: caps} = state) do
    {:reply, {:ok, caps}, state}
  end

  def handle_call(:server_capabilities, _from, state) do
    {:reply, {:error, :not_initialized}, state}
  end

  @impl GenServer
  def handle_call({:request, _method, _params, _opts}, _from, %{status: status} = state)
      when status != :ready do
    {:reply, {:error, {:not_ready, status}}, state}
  end

  def handle_call({:request, method, params, opts}, from, state) do
    timeout = Keyword.get(opts, :timeout, state.default_timeout)

    # Get next request ID
    id = RequestTracker.next_id(state.tracker_pid)

    # Build and send message
    msg = build_request_message(id, method, params)

    case state.transport_mod.send_message(state.transport_pid, msg) do
      :ok ->
        # Track the pending request
        :ok = RequestTracker.track(state.tracker_pid, id, method, from, timeout)
        {:noreply, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_call({:notify, _method, _params}, _from, %{status: status} = state)
      when status != :ready do
    {:reply, {:error, {:not_ready, status}}, state}
  end

  def handle_call({:notify, method, params}, _from, state) do
    msg = build_notification_message(method, params)
    result = state.transport_mod.send_message(state.transport_pid, msg)
    {:reply, result, state}
  end

  # ============================================================================
  # Connection Lifecycle
  # ============================================================================

  @impl GenServer
  def handle_info(:connect, %{status: :disconnected} = state) do
    Logger.debug("[Connection] Starting transport...")

    opts = [{:owner, self()} | state.transport_opts]

    case state.transport_mod.start_link(opts) do
      {:ok, transport_pid} ->
        Process.monitor(transport_pid)
        {:noreply, %{state | status: :connecting, transport_pid: transport_pid}}

      {:error, reason} ->
        Logger.error("[Connection] Failed to start transport: #{inspect(reason)}")
        {:stop, {:transport_failed, reason}, state}
    end
  end

  def handle_info(:connect, state) do
    # Already connecting or connected
    {:noreply, state}
  end

  # Transport is ready - start initialization
  @impl GenServer
  def handle_info({:transport_ready, pid}, %{status: :connecting, transport_pid: pid} = state) do
    Logger.debug("[Connection] Transport ready, starting initialization...")

    # Send initialize request
    id = RequestTracker.next_id(state.tracker_pid)

    msg =
      Messages.initialize(
        Capabilities.latest_version(),
        state.client_capabilities,
        state.client_info
      )

    full_msg = build_request_message(id, msg["method"], msg["params"])

    case state.transport_mod.send_message(pid, full_msg) do
      :ok ->
        # Track init request with longer timeout
        :ok = RequestTracker.track(state.tracker_pid, id, "initialize", nil, @init_timeout)
        {:noreply, %{state | status: :initializing}}

      {:error, reason} ->
        Logger.error("[Connection] Failed to send initialize: #{inspect(reason)}")
        {:stop, {:init_failed, reason}, state}
    end
  end

  # Handle transport messages
  @impl GenServer
  def handle_info({:transport_message, pid, message}, %{transport_pid: pid} = state) do
    handle_message(message, state)
  end

  # Handle transport closed
  @impl GenServer
  def handle_info({:transport_closed, pid, reason}, %{transport_pid: pid} = state) do
    Logger.info("[Connection] Transport closed: #{inspect(reason)}")

    # Fail all pending requests
    failed = RequestTracker.fail_all(state.tracker_pid, Errors.connection_closed())

    for {from, _method} <- failed, from != nil do
      GenServer.reply(from, {:error, Errors.connection_closed()})
    end

    {:noreply, %{state | status: :disconnected, transport_pid: nil}}
  end

  # Handle transport errors
  @impl GenServer
  def handle_info({:transport_error, pid, error}, %{transport_pid: pid} = state) do
    Logger.error("[Connection] Transport error: #{inspect(error)}")
    {:noreply, state}
  end

  # Handle transport process down
  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{transport_pid: pid} = state) do
    Logger.warning("[Connection] Transport process down: #{inspect(reason)}")

    failed = RequestTracker.fail_all(state.tracker_pid, Errors.connection_closed())

    for {from, _method} <- failed, from != nil do
      GenServer.reply(from, {:error, Errors.connection_closed()})
    end

    {:noreply, %{state | status: :disconnected, transport_pid: nil}}
  end

  @impl GenServer
  def handle_info(msg, state) do
    Logger.debug("[Connection] Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl GenServer
  def terminate(reason, state) do
    Logger.debug("[Connection] Terminating: #{inspect(reason)}")

    # Clean up tracker
    if state.tracker_pid do
      failed = RequestTracker.fail_all(state.tracker_pid, Errors.connection_closed())

      for {from, _method} <- failed, from != nil do
        GenServer.reply(from, {:error, Errors.connection_closed()})
      end

      GenServer.stop(state.tracker_pid)
    end

    # Close transport
    if state.transport_pid && Process.alive?(state.transport_pid) do
      state.transport_mod.close(state.transport_pid)
    end

    :ok
  end

  # ============================================================================
  # Message Handling
  # ============================================================================

  defp handle_message(message, state) do
    case JsonRpc.classify_message(message) do
      {:ok, {:response, msg}} ->
        handle_response(msg, state)

      {:ok, {:error_response, msg}} ->
        handle_error_response(msg, state)

      {:ok, {:request, msg}} ->
        handle_server_request(msg, state)

      {:ok, {:notification, msg}} ->
        handle_notification(msg, state)

      {:error, _} ->
        Logger.warning("[Connection] Invalid message received: #{inspect(message)}")
        {:noreply, state}
    end
  end

  defp handle_response(msg, %{status: :initializing} = state) do
    # This is the initialize response
    id = msg["id"]
    result = msg["result"]

    case RequestTracker.complete(state.tracker_pid, id) do
      {:ok, _from, "initialize"} ->
        # Process initialization result
        handle_init_response(result, state)

      {:error, :not_found} ->
        Logger.warning("[Connection] Received response for unknown request: #{id}")
        {:noreply, state}
    end
  end

  defp handle_response(msg, state) do
    id = msg["id"]
    result = msg["result"]

    case RequestTracker.complete(state.tracker_pid, id) do
      {:ok, from, _method} ->
        GenServer.reply(from, {:ok, result})
        {:noreply, state}

      {:error, :not_found} ->
        Logger.warning("[Connection] Received response for unknown request: #{id}")
        {:noreply, state}
    end
  end

  defp handle_error_response(msg, state) do
    id = msg["id"]
    error = msg["error"]

    case RequestTracker.fail(state.tracker_pid, id, error) do
      {:ok, from, _method} when from != nil ->
        error_struct = %Errors{
          code: error["code"],
          message: error["message"],
          data: error["data"]
        }

        GenServer.reply(from, {:error, error_struct})
        {:noreply, state}

      {:ok, nil, _method} ->
        # Init response error
        {:stop, {:init_failed, error}, state}

      {:error, :not_found} ->
        Logger.warning("[Connection] Received error for unknown request: #{id}")
        {:noreply, state}
    end
  end

  defp handle_init_response(result, state) do
    # Extract server info and capabilities
    {:ok, server_caps} = Capabilities.from_init_response(result)
    {:ok, server_info} = Capabilities.server_info_from_response(result)
    {:ok, protocol_version} = Capabilities.protocol_version_from_response(result)

    Logger.info("[Connection] Connected to #{server_info["name"]} v#{server_info["version"]}")

    # Send initialized notification
    notification = Messages.initialized_notification()
    msg = build_notification_message(notification["method"], nil)

    case state.transport_mod.send_message(state.transport_pid, msg) do
      :ok ->
        new_state = %{
          state
          | status: :ready,
            server_info: server_info,
            server_capabilities: server_caps,
            protocol_version: protocol_version
        }

        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("[Connection] Failed to send initialized notification: #{inspect(reason)}")
        {:stop, {:init_failed, reason}, state}
    end
  end

  defp handle_server_request(msg, state) do
    id = msg["id"]
    method = msg["method"]
    params = msg["params"] || %{}

    response =
      case method do
        "ping" ->
          {:ok, Messages.ping_response()}

        "roots/list" ->
          {:ok, Messages.roots_list_response([])}

        "sampling/createMessage" ->
          {:error, Messages.sampling_not_supported_error()}

        _ ->
          {:error, %{"code" => -32601, "message" => "Method not found: #{method}"}}
      end

    # Send response
    resp_msg =
      case response do
        {:ok, result} ->
          %{
            "jsonrpc" => "2.0",
            "id" => id,
            "result" => result
          }

        {:error, error} ->
          %{
            "jsonrpc" => "2.0",
            "id" => id,
            "error" => error
          }
      end

    state.transport_mod.send_message(state.transport_pid, resp_msg)

    # Also call notification handler if configured
    if state.notification_handler do
      call_notification_handler(state.notification_handler, {:request, method, params})
    end

    {:noreply, state}
  end

  defp handle_notification(msg, state) do
    method = msg["method"]
    params = msg["params"]

    Logger.debug("[Connection] Notification: #{method}")

    # Call notification handler if configured
    if state.notification_handler do
      call_notification_handler(state.notification_handler, {:notification, method, params})
    end

    {:noreply, state}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp transport_module(:stdio), do: Stdio
  defp transport_module(:http), do: Http

  defp build_transport_opts(:stdio, opts) do
    [
      command: Keyword.fetch!(opts, :command),
      args: Keyword.get(opts, :args, []),
      env: Keyword.get(opts, :env, []),
      cd: Keyword.get(opts, :cd)
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp build_transport_opts(:http, opts) do
    [
      url: Keyword.fetch!(opts, :url),
      headers: Keyword.get(opts, :headers, []),
      req_options: Keyword.get(opts, :req_options, [])
    ]
  end

  defp build_request_message(id, method, params) do
    msg = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method
    }

    if params && map_size(params) > 0 do
      Map.put(msg, "params", params)
    else
      msg
    end
  end

  defp build_notification_message(method, params) do
    msg = %{
      "jsonrpc" => "2.0",
      "method" => method
    }

    if params && map_size(params) > 0 do
      Map.put(msg, "params", params)
    else
      msg
    end
  end

  defp call_notification_handler({module, handler_state}, event) do
    try do
      module.handle_notification(event, handler_state)
    rescue
      e ->
        Logger.error("[Connection] Notification handler error: #{inspect(e)}")
    end
  end

  defp call_notification_handler(module, event) when is_atom(module) do
    try do
      module.handle_notification(event, nil)
    rescue
      e ->
        Logger.error("[Connection] Notification handler error: #{inspect(e)}")
    end
  end
end
