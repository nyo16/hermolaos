defmodule Hermolaos.Transport.Http do
  @moduledoc """
  HTTP/SSE transport for MCP communication with remote servers.

  This transport connects to remote MCP servers using HTTP POST for sending
  messages and optionally Server-Sent Events (SSE) for receiving streamed
  responses and server-initiated messages.

  ## How It Works

  1. Messages are sent via HTTP POST to the server endpoint
  2. Responses come as either JSON (immediate) or SSE stream
  3. Session state is maintained via `Mcp-Session-Id` header
  4. Optional GET endpoint can open persistent SSE stream for server notifications

  ## Example

      {:ok, transport} = Hermolaos.Transport.Http.start_link(
        owner: self(),
        url: "http://localhost:3000/mcp"
      )

      :ok = Hermolaos.Transport.Http.send_message(transport, %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{}
      })

  ## Messages Sent to Owner

  - `{:transport_ready, pid}` - Transport is ready
  - `{:transport_message, pid, map}` - Received a JSON message
  - `{:transport_closed, pid, reason}` - Connection closed
  - `{:transport_error, pid, error}` - Error occurred

  ## Options

  - `:owner` - PID to receive messages (required)
  - `:url` - Server endpoint URL (required)
  - `:headers` - Additional HTTP headers (default: [])
  - `:req_options` - Options passed to Req (default: [])
  - `:connect_timeout` - Connection timeout in ms (default: 30000)
  - `:receive_timeout` - Response timeout in ms (default: 60000)

  ## Performance Notes

  This transport uses Req with Finch for connection pooling. Multiple
  concurrent requests share the same connection pool, making it efficient
  for high-throughput scenarios.
  """

  @behaviour Hermolaos.Transport

  use GenServer
  require Logger

  # ============================================================================
  # Type Definitions
  # ============================================================================

  @type option ::
          {:owner, pid()}
          | {:url, String.t()}
          | {:headers, [{String.t(), String.t()}]}
          | {:req_options, keyword()}
          | {:connect_timeout, pos_integer()}
          | {:receive_timeout, pos_integer()}
          | {:name, GenServer.name()}

  @type state :: %{
          owner: pid(),
          url: String.t(),
          session_id: String.t() | nil,
          headers: [{String.t(), String.t()}],
          req_options: keyword(),
          connect_timeout: pos_integer(),
          receive_timeout: pos_integer(),
          connected: boolean(),
          pending_requests: %{reference() => pid()},
          stats: stats()
        }

  @type stats :: %{
          requests_sent: non_neg_integer(),
          responses_received: non_neg_integer(),
          errors: non_neg_integer()
        }

  @default_connect_timeout 30_000
  @default_receive_timeout 60_000

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Starts the HTTP transport.

  ## Options

  - `:owner` - PID to receive transport messages (required)
  - `:url` - The MCP server endpoint URL (required)
  - `:headers` - Additional HTTP headers (default: `[]`)
  - `:req_options` - Options passed to Req (default: `[]`)
  - `:connect_timeout` - Connection timeout in ms (default: 30000)
  - `:receive_timeout` - Response timeout in ms (default: 60000)
  - `:name` - GenServer name (optional)

  ## Examples

      {:ok, pid} = Hermolaos.Transport.Http.start_link(
        owner: self(),
        url: "http://localhost:3000/mcp",
        headers: [{"authorization", "Bearer token"}]
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
  Sends a JSON-RPC message to the server via HTTP POST.

  This is a synchronous call that waits for the HTTP request to complete.
  The response message(s) will be sent to the owner process.

  ## Examples

      :ok = Hermolaos.Transport.Http.send_message(transport, %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/list"
      })
  """
  @impl Hermolaos.Transport
  @spec send_message(GenServer.server(), map()) :: :ok | {:error, term()}
  def send_message(transport, message) when is_map(message) do
    GenServer.call(transport, {:send, message}, :infinity)
  end

  @doc """
  Sends a message asynchronously (non-blocking).

  The HTTP request is performed in a background task.
  """
  @impl Hermolaos.Transport
  @spec cast_message(GenServer.server(), map()) :: :ok
  def cast_message(transport, message) when is_map(message) do
    GenServer.cast(transport, {:send, message})
  end

  @doc """
  Closes the transport.
  """
  @impl Hermolaos.Transport
  @spec close(GenServer.server()) :: :ok
  def close(transport) do
    GenServer.stop(transport, :normal)
  end

  @doc """
  Checks if the transport is connected.
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
    url = Keyword.fetch!(opts, :url)
    headers = Keyword.get(opts, :headers, [])
    req_options = Keyword.get(opts, :req_options, [])
    connect_timeout = Keyword.get(opts, :connect_timeout, @default_connect_timeout)
    receive_timeout = Keyword.get(opts, :receive_timeout, @default_receive_timeout)

    state = %{
      owner: owner,
      url: url,
      session_id: nil,
      headers: headers,
      req_options: req_options,
      connect_timeout: connect_timeout,
      receive_timeout: receive_timeout,
      connected: true,
      pending_requests: %{},
      stats: %{
        requests_sent: 0,
        responses_received: 0,
        errors: 0
      }
    }

    # HTTP transport is immediately ready
    send(owner, {:transport_ready, self()})

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:send, message}, from, state) do
    # Perform HTTP request asynchronously to not block GenServer
    ref = make_ref()
    parent = self()

    Task.start(fn ->
      result = do_send_request(message, state)
      send(parent, {:request_complete, ref, result})
    end)

    new_state = %{state | pending_requests: Map.put(state.pending_requests, ref, from)}
    {:noreply, update_stats(new_state, :requests_sent)}
  end

  @impl GenServer
  def handle_call(:connected?, _from, state) do
    {:reply, state.connected, state}
  end

  @impl GenServer
  def handle_call(:info, _from, state) do
    info = %{
      url: state.url,
      session_id: state.session_id,
      connected: state.connected,
      pending_requests: map_size(state.pending_requests),
      stats: state.stats
    }

    {:reply, info, state}
  end

  @impl GenServer
  def handle_cast({:send, message}, state) do
    # Fire and forget
    Task.start(fn ->
      do_send_request(message, state)
    end)

    {:noreply, update_stats(state, :requests_sent)}
  end

  @impl GenServer
  def handle_info({:request_complete, ref, result}, state) do
    {from, pending} = Map.pop(state.pending_requests, ref)

    new_state =
      case result do
        {:ok, session_id, messages} ->
          # Deliver messages to owner
          for msg <- messages do
            send(state.owner, {:transport_message, self(), msg})
          end

          state
          |> maybe_update_session_id(session_id)
          |> update_stats(:responses_received)

        {:error, reason} ->
          Logger.warning("[Hermolaos.Transport.Http] Request failed: #{inspect(reason)}")
          send(state.owner, {:transport_error, self(), reason})
          update_stats(state, :errors)
      end

    # Reply to the caller
    if from do
      case result do
        {:ok, _, _} -> GenServer.reply(from, :ok)
        {:error, reason} -> GenServer.reply(from, {:error, reason})
      end
    end

    {:noreply, %{new_state | pending_requests: pending}}
  end

  @impl GenServer
  def handle_info(msg, state) do
    Logger.debug("[Hermolaos.Transport.Http] Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    # Cancel any pending requests
    for {_ref, from} <- state.pending_requests do
      GenServer.reply(from, {:error, :transport_closed})
    end

    send(state.owner, {:transport_closed, self(), :normal})
    :ok
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp do_send_request(message, state) do
    headers = build_headers(state)

    req_opts =
      [
        url: state.url,
        method: :post,
        json: message,
        headers: headers,
        connect_options: [timeout: state.connect_timeout],
        receive_timeout: state.receive_timeout
      ] ++ state.req_options

    case Req.request(req_opts) do
      {:ok, response} ->
        handle_response(response)

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:transport_error, reason}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_headers(state) do
    base_headers = [
      {"accept", "application/json, text/event-stream"},
      {"content-type", "application/json"}
    ]

    session_header =
      if state.session_id do
        [{"mcp-session-id", state.session_id}]
      else
        []
      end

    base_headers ++ session_header ++ state.headers
  end

  defp handle_response(%{status: status} = response) when status in 200..299 do
    session_id = get_session_id(response.headers)
    content_type = get_content_type(response.headers)

    messages = parse_response_body(response.body, content_type)
    {:ok, session_id, messages}
  end

  defp handle_response(%{status: 202}) do
    # 202 Accepted - no content (for notifications)
    {:ok, nil, []}
  end

  defp handle_response(%{status: status, body: body}) do
    {:error, {:http_error, status, body}}
  end

  defp parse_response_body(body, _content_type) when is_map(body) do
    # Req already decoded JSON
    [body]
  end

  defp parse_response_body(body, "application/json" <> _) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> [decoded]
      {:ok, decoded} when is_list(decoded) -> decoded
      _ -> []
    end
  end

  defp parse_response_body(body, "text/event-stream" <> _) when is_binary(body) do
    parse_sse_stream(body)
  end

  defp parse_response_body(_body, _content_type) do
    []
  end

  defp parse_sse_stream(body) do
    body
    |> String.split("\n\n")
    |> Enum.flat_map(&parse_sse_event/1)
  end

  defp parse_sse_event(event) do
    lines = String.split(event, "\n")

    data =
      lines
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map(&String.trim_leading(&1, "data:"))
      |> Enum.map(&String.trim/1)
      |> Enum.join("\n")

    if data != "" do
      case Jason.decode(data) do
        {:ok, decoded} when is_map(decoded) -> [decoded]
        _ -> []
      end
    else
      []
    end
  end

  defp get_session_id(headers) do
    find_header(headers, "mcp-session-id")
  end

  defp get_content_type(headers) do
    find_header(headers, "content-type") || "application/json"
  end

  defp find_header(headers, name) do
    name_lower = String.downcase(name)

    Enum.find_value(headers, fn
      {k, v} when is_binary(k) ->
        if String.downcase(k) == name_lower, do: v

      {k, v} when is_list(k) ->
        if String.downcase(to_string(k)) == name_lower, do: to_string(v)

      _ ->
        nil
    end)
  end

  defp maybe_update_session_id(state, nil), do: state
  defp maybe_update_session_id(state, session_id), do: %{state | session_id: session_id}

  defp update_stats(state, :requests_sent) do
    update_in(state.stats.requests_sent, &(&1 + 1))
  end

  defp update_stats(state, :responses_received) do
    update_in(state.stats.responses_received, &(&1 + 1))
  end

  defp update_stats(state, :errors) do
    update_in(state.stats.errors, &(&1 + 1))
  end
end
