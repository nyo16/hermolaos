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
          protocol_version: String.t() | nil,
          last_event_id: String.t() | nil,
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
  Sets the negotiated protocol version for the `MCP-Protocol-Version` header.

  Called by the connection after a successful initialization handshake.
  """
  @spec set_protocol_version(GenServer.server(), String.t()) :: :ok
  def set_protocol_version(transport, version) when is_binary(version) do
    GenServer.cast(transport, {:set_protocol_version, version})
  end

  @doc """
  Terminates the MCP session by sending an HTTP DELETE request.

  Per the 2025-11-25 spec, clients SHOULD send DELETE to explicitly terminate a session.
  """
  @spec terminate_session(GenServer.server()) :: :ok | {:error, term()}
  def terminate_session(transport) do
    GenServer.call(transport, :terminate_session)
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
      protocol_version: nil,
      last_event_id: nil,
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
  def handle_call(:terminate_session, _from, %{session_id: nil} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:terminate_session, _from, state) do
    result = do_delete_session(state)
    {:reply, result, %{state | session_id: nil}}
  end

  @impl GenServer
  def handle_cast({:set_protocol_version, version}, state) do
    {:noreply, %{state | protocol_version: version}}
  end

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
        {:ok, session_id, messages, last_event_id} ->
          # Deliver messages to owner
          for msg <- messages do
            send(state.owner, {:transport_message, self(), msg})
          end

          state
          |> maybe_update_session_id(session_id)
          |> maybe_update_last_event_id(last_event_id)
          |> update_stats(:responses_received)

        {:error, reason} ->
          Logger.warning("[Hermolaos.Transport.Http] Request failed: #{inspect(reason)}")
          send(state.owner, {:transport_error, self(), reason})
          update_stats(state, :errors)
      end

    # Reply to the caller
    if from do
      case result do
        {:ok, _, _, _} -> GenServer.reply(from, :ok)
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

  defp do_delete_session(state) do
    headers = build_headers(state)

    req_opts =
      [
        url: state.url,
        method: :delete,
        headers: headers,
        connect_options: [timeout: state.connect_timeout],
        receive_timeout: state.receive_timeout
      ] ++ state.req_options

    case Req.request(req_opts) do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_headers(state) do
    base_headers = [
      {"accept", "application/json, text/event-stream"},
      {"content-type", "application/json"}
    ]

    protocol_version_header =
      if state.protocol_version do
        [{"mcp-protocol-version", state.protocol_version}]
      else
        []
      end

    session_header =
      if state.session_id do
        [{"mcp-session-id", state.session_id}]
      else
        []
      end

    last_event_id_header =
      if state.last_event_id do
        [{"last-event-id", state.last_event_id}]
      else
        []
      end

    base_headers ++
      protocol_version_header ++ session_header ++ last_event_id_header ++ state.headers
  end

  defp handle_response(%{status: 202}) do
    # 202 Accepted - no content (for notifications/responses sent by client)
    {:ok, nil, [], nil}
  end

  defp handle_response(%{status: status} = response) when status in 200..299 do
    session_id = get_session_id(response.headers)
    content_type = get_content_type(response.headers)

    {messages, last_event_id} = parse_response_body(response.body, content_type)
    {:ok, session_id, messages, last_event_id}
  end

  defp handle_response(%{status: status, body: body}) do
    {:error, {:http_error, status, body}}
  end

  defp parse_response_body(body, _content_type) when is_map(body) do
    # Req already decoded JSON
    {[body], nil}
  end

  defp parse_response_body(body, "application/json" <> _) when is_binary(body) do
    messages =
      case Jason.decode(body) do
        {:ok, decoded} when is_map(decoded) -> [decoded]
        {:ok, decoded} when is_list(decoded) -> decoded
        _ -> []
      end

    {messages, nil}
  end

  defp parse_response_body(body, "text/event-stream" <> _) when is_binary(body) do
    parse_sse_stream(body)
  end

  defp parse_response_body(_body, _content_type) do
    {[], nil}
  end

  # Parses SSE stream, extracting messages and tracking the last event ID
  # for resumability per the 2025-11-25 spec.
  defp parse_sse_stream(body) do
    events = String.split(body, "\n\n")

    {messages, last_id} =
      Enum.reduce(events, {[], nil}, fn event, {msgs, last_id} ->
        {new_msgs, event_id} = parse_sse_event(event)
        {msgs ++ new_msgs, event_id || last_id}
      end)

    {messages, last_id}
  end

  defp parse_sse_event(event) do
    lines = String.split(event, "\n")

    {data_lines, id} =
      Enum.reduce(lines, {[], nil}, fn line, {data_acc, id_acc} ->
        cond do
          String.starts_with?(line, "data:") ->
            value = line |> String.trim_leading("data:") |> String.trim()
            {data_acc ++ [value], id_acc}

          String.starts_with?(line, "id:") ->
            value = line |> String.trim_leading("id:") |> String.trim()
            {data_acc, value}

          true ->
            {data_acc, id_acc}
        end
      end)

    data = Enum.join(data_lines, "\n")

    messages =
      if data != "" do
        case Jason.decode(data) do
          {:ok, decoded} when is_map(decoded) -> [decoded]
          _ -> []
        end
      else
        []
      end

    {messages, id}
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

  defp maybe_update_last_event_id(state, nil), do: state
  defp maybe_update_last_event_id(state, id), do: %{state | last_event_id: id}

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
