defmodule Charon.Transport do
  @moduledoc """
  Behaviour defining the transport interface for MCP communication.

  A transport is responsible for the low-level communication between an MCP
  client and server. MCP supports two standard transports:

  - **stdio**: Communication via stdin/stdout with a subprocess
  - **HTTP/SSE**: Communication via HTTP POST with optional Server-Sent Events

  ## Implementing a Custom Transport

  To create a custom transport, implement this behaviour:

      defmodule MyApp.CustomTransport do
        @behaviour Charon.Transport
        use GenServer

        @impl Charon.Transport
        def start_link(opts) do
          GenServer.start_link(__MODULE__, opts)
        end

        @impl Charon.Transport
        def send_message(transport, message) do
          GenServer.call(transport, {:send, message})
        end

        @impl Charon.Transport
        def close(transport) do
          GenServer.stop(transport)
        end

        @impl Charon.Transport
        def connected?(transport) do
          GenServer.call(transport, :connected?)
        end

        # GenServer callbacks...
      end

  ## Message Flow

  Transports communicate with their owner (typically a Connection GenServer)
  via messages:

  - `{:transport_ready, pid}` - Transport is ready for messages
  - `{:transport_message, pid, message}` - Received a message from server
  - `{:transport_closed, pid, reason}` - Transport connection closed
  - `{:transport_error, pid, error}` - Transport error occurred

  ## Options

  All transports accept these common options:

  - `:owner` - The PID to send messages to (required)
  - `:name` - Optional name for the transport process
  """

  @type t :: pid() | GenServer.name()
  @type message :: map()
  @type send_result :: :ok | {:error, term()}
  @type start_result :: {:ok, pid()} | {:error, term()}

  @doc """
  Starts the transport process.

  The transport should send `{:transport_ready, self()}` to the owner
  when it's ready to send and receive messages.

  ## Options

  - `:owner` - PID to receive transport messages (required)
  - Other options are transport-specific

  ## Returns

  - `{:ok, pid}` on success
  - `{:error, reason}` on failure
  """
  @callback start_link(opts :: keyword()) :: start_result()

  @doc """
  Sends a JSON-RPC message through the transport.

  The message should be a map that will be JSON-encoded by the transport.

  ## Parameters

  - `transport` - The transport process (PID or name)
  - `message` - The JSON-RPC message map to send

  ## Returns

  - `:ok` on success
  - `{:error, reason}` on failure

  ## Notes

  This function may block until the message is sent, or it may be
  asynchronous depending on the transport implementation. For non-blocking
  sends, consider using `cast_message/2` if available.
  """
  @callback send_message(transport :: t(), message :: message()) :: send_result()

  @doc """
  Closes the transport connection.

  This should gracefully shut down the transport, cleaning up any resources.
  The transport should send `{:transport_closed, self(), :normal}` to the
  owner before terminating.

  ## Returns

  - `:ok` on success
  """
  @callback close(transport :: t()) :: :ok

  @doc """
  Checks if the transport is currently connected.

  ## Returns

  - `true` if connected and ready for messages
  - `false` otherwise
  """
  @callback connected?(transport :: t()) :: boolean()

  # ============================================================================
  # Optional Callbacks
  # ============================================================================

  @doc """
  Sends a message asynchronously (fire-and-forget).

  This is an optional callback for transports that support non-blocking sends.
  If not implemented, defaults to calling `send_message/2`.
  """
  @callback cast_message(transport :: t(), message :: message()) :: :ok

  @doc """
  Returns transport-specific information.

  This is an optional callback for transports to expose metadata like
  session IDs, connection state, or statistics.
  """
  @callback info(transport :: t()) :: map()

  @optional_callbacks [cast_message: 2, info: 1]

  # ============================================================================
  # Helper Functions
  # ============================================================================

  @doc """
  Sends a message, falling back to sync send if async is not available.

  ## Examples

      Charon.Transport.send(transport_mod, transport_pid, message)
  """
  @spec send(module(), t(), message()) :: send_result()
  def send(module, transport, message) do
    if function_exported?(module, :cast_message, 2) do
      module.cast_message(transport, message)
      :ok
    else
      module.send_message(transport, message)
    end
  end

  @doc """
  Validates that a module implements the Transport behaviour.

  ## Examples

      iex> Charon.Transport.valid_transport?(Charon.Transport.Stdio)
      true

      iex> Charon.Transport.valid_transport?(String)
      false
  """
  @spec valid_transport?(module()) :: boolean()
  def valid_transport?(module) when is_atom(module) do
    behaviours = module.module_info(:attributes)[:behaviour] || []
    __MODULE__ in behaviours
  rescue
    _ -> false
  end
end
