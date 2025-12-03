defmodule Hermolaos.Transport.Stdio do
  @moduledoc """
  Stdio transport for MCP communication with local subprocess servers.

  This transport launches an MCP server as a subprocess and communicates
  via stdin/stdout using newline-delimited JSON messages.

  ## How It Works

  1. The transport spawns the server command as a subprocess using Erlang ports
  2. JSON-RPC messages are written to the server's stdin (one per line)
  3. Responses are read from stdout and buffered until complete
  4. The owner process receives messages via `{:transport_message, pid, msg}`

  ## Example

      {:ok, transport} = Hermolaos.Transport.Stdio.start_link(
        owner: self(),
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
      )

      :ok = Hermolaos.Transport.Stdio.send_message(transport, %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{}
      })

      # Wait for response
      receive do
        {:transport_message, ^transport, message} ->
          IO.inspect(message)
      end

  ## Messages Sent to Owner

  - `{:transport_ready, pid}` - Transport is ready
  - `{:transport_message, pid, map}` - Received a decoded JSON message
  - `{:transport_closed, pid, reason}` - Server process exited
  - `{:transport_error, pid, error}` - Error occurred

  ## Options

  - `:owner` - PID to receive messages (required)
  - `:command` - Command to execute (required)
  - `:args` - Command arguments (default: [])
  - `:env` - Environment variables as keyword list (default: [])
  - `:cd` - Working directory for the command (default: current directory)
  """

  @behaviour Hermolaos.Transport

  use GenServer
  require Logger

  alias Hermolaos.Transport.MessageBuffer

  # ============================================================================
  # Type Definitions
  # ============================================================================

  @type option ::
          {:owner, pid()}
          | {:command, String.t()}
          | {:args, [String.t()]}
          | {:env, [{String.t(), String.t()}]}
          | {:cd, String.t()}
          | {:name, GenServer.name()}

  @type state :: %{
          owner: pid(),
          port: port() | nil,
          command: String.t(),
          args: [String.t()],
          env: [{charlist(), charlist()}],
          cd: String.t() | nil,
          buffer: MessageBuffer.t(),
          connected: boolean(),
          exit_status: integer() | nil
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Starts the stdio transport.

  ## Options

  - `:owner` - PID to receive transport messages (required)
  - `:command` - The command to execute (required)
  - `:args` - List of command arguments (default: `[]`)
  - `:env` - Environment variables as `[{name, value}]` (default: `[]`)
  - `:cd` - Working directory for the command (optional)
  - `:name` - GenServer name (optional)

  ## Examples

      {:ok, pid} = Hermolaos.Transport.Stdio.start_link(
        owner: self(),
        command: "/usr/bin/python3",
        args: ["-m", "mcp_server"]
      )
  """
  @impl Hermolaos.Transport
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)

    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Sends a JSON-RPC message to the server via stdin.

  The message map is JSON-encoded and sent as a single line.

  ## Examples

      :ok = Hermolaos.Transport.Stdio.send_message(transport, %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "ping"
      })
  """
  @impl Hermolaos.Transport
  @spec send_message(GenServer.server(), map()) :: :ok | {:error, term()}
  def send_message(transport, message) when is_map(message) do
    GenServer.call(transport, {:send, message})
  end

  @doc """
  Sends a message asynchronously (non-blocking).
  """
  @impl Hermolaos.Transport
  @spec cast_message(GenServer.server(), map()) :: :ok
  def cast_message(transport, message) when is_map(message) do
    GenServer.cast(transport, {:send, message})
  end

  @doc """
  Closes the transport, terminating the subprocess.
  """
  @impl Hermolaos.Transport
  @spec close(GenServer.server()) :: :ok
  def close(transport) do
    GenServer.stop(transport, :normal)
  end

  @doc """
  Checks if the transport is connected to a running subprocess.
  """
  @impl Hermolaos.Transport
  @spec connected?(GenServer.server()) :: boolean()
  def connected?(transport) do
    GenServer.call(transport, :connected?)
  end

  @doc """
  Returns transport information and statistics.
  """
  @impl Hermolaos.Transport
  @spec info(GenServer.server()) :: map()
  def info(transport) do
    GenServer.call(transport, :info)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl GenServer
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    command = Keyword.fetch!(opts, :command)
    args = Keyword.get(opts, :args, [])
    env = Keyword.get(opts, :env, []) |> Enum.map(fn {k, v} -> {to_charlist(k), to_charlist(v)} end)
    cd = Keyword.get(opts, :cd)

    state = %{
      owner: owner,
      port: nil,
      command: command,
      args: args,
      env: env,
      cd: cd,
      buffer: MessageBuffer.new(),
      connected: false,
      exit_status: nil
    }

    # Start the port asynchronously to not block init
    send(self(), :start_port)

    {:ok, state}
  end

  @impl GenServer
  def handle_info(:start_port, state) do
    case start_port(state) do
      {:ok, port} ->
        Logger.debug("[Hermolaos.Transport.Stdio] Started port for #{state.command}")
        send(state.owner, {:transport_ready, self()})
        {:noreply, %{state | port: port, connected: true}}

      {:error, reason} ->
        Logger.error("[Hermolaos.Transport.Stdio] Failed to start port: #{inspect(reason)}")
        send(state.owner, {:transport_error, self(), {:start_failed, reason}})
        {:stop, {:start_failed, reason}, state}
    end
  end

  @impl GenServer
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {messages, new_buffer} = MessageBuffer.append(state.buffer, data)

    # Send each message to owner
    for msg <- messages do
      send(state.owner, {:transport_message, self(), msg})
    end

    {:noreply, %{state | buffer: new_buffer}}
  end

  @impl GenServer
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.debug("[Hermolaos.Transport.Stdio] Process exited with status #{status}")

    # Flush any remaining buffered messages
    {messages, _buffer} = MessageBuffer.reset(state.buffer)

    for msg <- messages do
      send(state.owner, {:transport_message, self(), msg})
    end

    reason = if status == 0, do: :normal, else: {:exit, status}
    send(state.owner, {:transport_closed, self(), reason})

    {:noreply, %{state | connected: false, exit_status: status, port: nil}}
  end

  @impl GenServer
  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    Logger.warning("[Hermolaos.Transport.Stdio] Port exited: #{inspect(reason)}")
    send(state.owner, {:transport_closed, self(), reason})
    {:noreply, %{state | connected: false, port: nil}}
  end

  @impl GenServer
  def handle_info(msg, state) do
    Logger.debug("[Hermolaos.Transport.Stdio] Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:send, _message}, _from, %{connected: false} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  @impl GenServer
  def handle_call({:send, message}, _from, %{port: port} = state) when port != nil do
    case Jason.encode(message) do
      {:ok, json} ->
        # Send JSON followed by newline
        Port.command(port, [json, "\n"])
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, {:encode_failed, reason}}, state}
    end
  end

  @impl GenServer
  def handle_call(:connected?, _from, state) do
    {:reply, state.connected, state}
  end

  @impl GenServer
  def handle_call(:info, _from, state) do
    info = %{
      command: state.command,
      args: state.args,
      connected: state.connected,
      exit_status: state.exit_status,
      buffer_stats: MessageBuffer.stats(state.buffer),
      buffer_pending: MessageBuffer.has_pending?(state.buffer)
    }

    {:reply, info, state}
  end

  @impl GenServer
  def handle_cast({:send, _message}, %{connected: false} = state) do
    Logger.warning("[Hermolaos.Transport.Stdio] Cannot send: not connected")
    {:noreply, state}
  end

  @impl GenServer
  def handle_cast({:send, message}, %{port: port} = state) when port != nil do
    case Jason.encode(message) do
      {:ok, json} ->
        Port.command(port, [json, "\n"])

      {:error, reason} ->
        Logger.error("[Hermolaos.Transport.Stdio] Failed to encode message: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  @impl GenServer
  def terminate(reason, %{port: port}) when port != nil do
    Logger.debug("[Hermolaos.Transport.Stdio] Terminating: #{inspect(reason)}")

    # Close stdin to signal EOF to the subprocess
    Port.close(port)

    # The port will exit, but we're terminating anyway
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp start_port(state) do
    # Find the executable
    command = find_executable(state.command)

    if command do
      port_opts =
        [
          :binary,
          :exit_status,
          :use_stdio,
          :hide,
          {:args, state.args},
          {:env, state.env}
        ]
        |> maybe_add_cd(state.cd)

      try do
        port = Port.open({:spawn_executable, command}, port_opts)
        {:ok, port}
      rescue
        e -> {:error, e}
      end
    else
      {:error, {:command_not_found, state.command}}
    end
  end

  defp find_executable(command) do
    # Check if it's an absolute path
    if String.starts_with?(command, "/") do
      if File.exists?(command), do: command, else: nil
    else
      # Search in PATH
      System.find_executable(command)
    end
  end

  defp maybe_add_cd(opts, nil), do: opts
  defp maybe_add_cd(opts, cd), do: [{:cd, to_charlist(cd)} | opts]
end
