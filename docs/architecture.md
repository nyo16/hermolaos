# Charon Architecture

This document describes the internal architecture of the Charon MCP client library.

## Overview

Charon is an Elixir client for the Model Context Protocol (MCP). It provides a clean API for connecting to MCP servers and invoking tools, reading resources, and using prompts.

```
┌─────────────────────────────────────────────────────────────┐
│                      Application                            │
├─────────────────────────────────────────────────────────────┤
│                       Charon API                            │
│    connect/2, list_tools/1, call_tool/3, ping/1, etc.       │
├─────────────────────────────────────────────────────────────┤
│                    Charon.Pool (optional)                   │
│            Connection pooling & load balancing              │
├─────────────────────────────────────────────────────────────┤
│                  Charon.Client.Connection                   │
│           GenServer state machine per connection            │
├────────────────────────┬────────────────────────────────────┤
│   Transport Layer      │       Protocol Layer               │
│  ┌──────────────────┐  │  ┌──────────────────────────────┐  │
│  │ Transport.Stdio  │  │  │ Protocol.JsonRpc             │  │
│  │ Transport.HTTP   │  │  │ Protocol.Messages            │  │
│  │ MessageBuffer    │  │  │ Protocol.Capabilities        │  │
│  └──────────────────┘  │  │ Protocol.Errors              │  │
│                        │  └──────────────────────────────┘  │
├────────────────────────┴────────────────────────────────────┤
│               Client Support Modules                        │
│     RequestTracker (ETS) │ NotificationHandler              │
└─────────────────────────────────────────────────────────────┘
```

## Module Structure

### Public API (`lib/charon.ex`)

The main entry point for users. Provides a simple, consistent API that delegates to the underlying connection management.

Key functions:
- `connect/2` - Establish a new MCP connection
- `disconnect/1` - Close a connection
- `list_tools/1`, `call_tool/3` - Tool operations
- `list_resources/1`, `read_resource/2` - Resource operations
- `list_prompts/1`, `get_prompt/3` - Prompt operations
- `ping/1` - Health check

### Connection Management (`lib/charon/client/connection.ex`)

A GenServer that manages the lifecycle of a single MCP connection. Implements a state machine:

```
┌──────────────┐     ┌────────────────┐     ┌───────────────┐     ┌─────────┐
│ disconnected │────▶│   connecting   │────▶│ initializing  │────▶│  ready  │
└──────────────┘     └────────────────┘     └───────────────┘     └─────────┘
       ▲                                                                │
       └────────────────────── error/disconnect ────────────────────────┘
```

States:
- **disconnected**: Initial state, no transport active
- **connecting**: Transport is starting up
- **initializing**: MCP initialize handshake in progress
- **ready**: Connection is fully established, can process requests

### Transport Layer

#### Transport Behaviour (`lib/charon/transport/behaviour.ex`)

Defines the interface that all transports must implement:

```elixir
@callback start_link(opts :: keyword()) :: GenServer.on_start()
@callback send_message(transport :: t(), message :: binary()) :: :ok | {:error, term()}
@callback stop(transport :: t()) :: :ok
```

#### Stdio Transport (`lib/charon/transport/stdio.ex`)

Uses Erlang ports to communicate with subprocess MCP servers:

```
┌─────────────────┐                    ┌─────────────────┐
│  Charon Client  │                    │   MCP Server    │
│                 │                    │   (subprocess)  │
│  ┌───────────┐  │     stdin/stdout   │                 │
│  │   Port    │──┼────────────────────┼──▶ server.exe   │
│  └───────────┘  │                    │                 │
└─────────────────┘                    └─────────────────┘
```

Features:
- Spawns server as subprocess via `Port.open/2`
- Binary, line-based communication
- Automatic process cleanup on connection close
- Environment variable passthrough

#### HTTP Transport (`lib/charon/transport/http.ex`)

Uses Req to communicate with HTTP-based MCP servers:

```
┌─────────────────┐                    ┌─────────────────┐
│  Charon Client  │      HTTP POST     │   MCP Server    │
│                 │────────────────────▶│   (HTTP)        │
│  ┌───────────┐  │◀────────────────────│                 │
│  │    Req    │  │   JSON / SSE       │                 │
│  └───────────┘  │                    └─────────────────┘
└─────────────────┘
```

Features:
- JSON-RPC over HTTP POST
- Server-Sent Events (SSE) for streaming responses
- Session ID tracking via `Mcp-Session-Id` header
- Connection pooling via Finch (Req's HTTP client)

#### Message Buffer (`lib/charon/transport/message_buffer.ex`)

Handles the newline-delimited JSON format used by MCP:

```
{"jsonrpc":"2.0","id":1,"method":"ping"}\n
{"jsonrpc":"2.0","id":2,"method":"tools/list"}\n
```

Features:
- Accumulates partial data chunks
- Extracts complete messages on newline boundaries
- Handles edge cases (empty lines, partial JSON)
- Tracks statistics (bytes received, parse errors)

### Protocol Layer

#### JSON-RPC (`lib/charon/protocol/json_rpc.ex`)

Implements JSON-RPC 2.0 message encoding/decoding:

Message types:
- **Request**: `{id, method, params}` - Expects response
- **Notification**: `{method, params}` - No response expected
- **Response**: `{id, result}` - Success response
- **Error Response**: `{id, error}` - Error response

#### Messages (`lib/charon/protocol/messages.ex`)

Builds MCP-specific message payloads:

```elixir
Messages.initialize(client_info, capabilities)
Messages.tools_list()
Messages.tools_call("tool_name", %{arg: "value"})
Messages.resources_read("file:///path")
```

#### Capabilities (`lib/charon/protocol/capabilities.ex`)

Handles capability negotiation between client and server:

```elixir
# Client capabilities (what we support)
%{
  "roots" => %{"listChanged" => true},
  "sampling" => %{}
}

# Server capabilities (what server supports)
%{
  "tools" => %{},
  "resources" => %{"subscribe" => true},
  "prompts" => %{}
}
```

#### Errors (`lib/charon/protocol/errors.ex`)

Defines MCP error codes and provides helpers:

| Code | Name | Description |
|------|------|-------------|
| -32700 | Parse Error | Invalid JSON |
| -32600 | Invalid Request | Not a valid JSON-RPC request |
| -32601 | Method Not Found | Unknown method |
| -32602 | Invalid Params | Invalid method parameters |
| -32603 | Internal Error | Internal JSON-RPC error |
| -32001 | Request Timeout | Request timed out |
| -32002 | Resource Not Found | Resource doesn't exist |
| -32003 | Capability Not Supported | Server doesn't support capability |

### Request Tracking (`lib/charon/client/request_tracker.ex`)

ETS-backed storage for correlating requests with responses:

```
┌────────────────────────────────────────────────────────────┐
│                     ETS Table                              │
├────────┬─────────────┬────────────────┬───────────────────┤
│   ID   │   Method    │     From       │    Timeout Ref    │
├────────┼─────────────┼────────────────┼───────────────────┤
│    1   │ tools/list  │ {pid, ref}     │ #Reference<...>   │
│    2   │ ping        │ {pid, ref}     │ #Reference<...>   │
└────────┴─────────────┴────────────────┴───────────────────┘
```

Features:
- O(1) lookups via ETS
- Monotonically increasing integer IDs
- Automatic timeout handling with per-request timers
- Statistics tracking (tracked, completed, failed, timed out)

### Notification Handling (`lib/charon/client/notification_handler.ex`)

Behaviour for handling server-initiated messages:

```elixir
defmodule MyHandler do
  @behaviour Charon.Client.NotificationHandler

  @impl true
  def handle_notification({:notification, "notifications/tools/list_changed", _}, state) do
    # Tools list changed, maybe refresh cache
    {:ok, state}
  end
end
```

Built-in handlers:
- `DefaultNotificationHandler` - Logs notifications
- `PubSubNotificationHandler` - Broadcasts via Phoenix.PubSub or Registry

### Connection Pool (`lib/charon/pool.ex`)

Manages multiple connections for high-throughput scenarios:

```
┌─────────────────────────────────────────────────────────────┐
│                      Charon.Pool                            │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              DynamicSupervisor                       │   │
│  │                                                      │   │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐           │   │
│  │  │ Conn #1  │  │ Conn #2  │  │ Conn #3  │  ...      │   │
│  │  └──────────┘  └──────────┘  └──────────┘           │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  Strategies: :round_robin | :random | :least_busy          │
└─────────────────────────────────────────────────────────────┘
```

## Request Flow

### Making a Tool Call

```
1. User calls Charon.call_tool(conn, "tool_name", args)
   │
2. Connection.call_tool/3 called
   │
3. RequestTracker assigns ID and stores caller info
   │
4. Message built: Messages.tools_call("tool_name", args)
   │
5. JSON-RPC encoded: JsonRpc.encode_request(id, "tools/call", params)
   │
6. Transport.send_message(transport, json)
   │
7. Transport sends to server (stdio/HTTP)
   │
   ▼ (async - server processing)
   │
8. Server response arrives at transport
   │
9. MessageBuffer extracts complete JSON message
   │
10. JsonRpc.decode/1 parses response
    │
11. RequestTracker.complete/2 retrieves caller
    │
12. GenServer.reply(from, {:ok, result})
    │
13. User receives {:ok, %{content: [...]}}
```

### MCP Initialization Handshake

```
Client                                  Server
   │                                       │
   │──── initialize ─────────────────────▶│
   │     {protocolVersion, clientInfo,     │
   │      capabilities}                    │
   │                                       │
   │◀──── response ────────────────────────│
   │     {protocolVersion, serverInfo,     │
   │      capabilities}                    │
   │                                       │
   │──── notifications/initialized ──────▶│
   │     (no response expected)            │
   │                                       │
   │        Connection Ready               │
```

## Concurrency Model

- Each `Connection` is an isolated GenServer (crash isolation)
- `RequestTracker` uses ETS for concurrent-safe lookups
- Pool uses `DynamicSupervisor` for connection management
- Transports handle I/O asynchronously

## Error Handling

### Transport Errors
- Connection closed → All pending requests failed
- Send error → Request fails immediately
- Process crash → Supervisor restarts transport

### Protocol Errors
- Parse error → Error response to client
- Invalid request → Error response to client
- Timeout → Request fails with timeout error

### Request Errors
- Server returns error → Wrapped in `Charon.Error`
- Timeout → `{:error, %Charon.Error{code: -32001}}`
