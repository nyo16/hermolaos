# Design Decisions

This document explains the key architectural and implementation decisions made in Hermolaos.

## Why Build From Scratch?

While existing Elixir MCP libraries exist (hermes_mcp, anubis_mcp), we chose to build from scratch for several reasons:

1. **Full control over design** - Custom architecture optimized for our use cases
2. **HTTP client choice** - We specifically wanted to use Req for its modern API and Finch-based performance
3. **Learning opportunity** - Deep understanding of MCP protocol internals
4. **Minimal dependencies** - Only essential dependencies, no framework lock-in

## Transport Layer Decisions

### Stdio Transport: Erlang Ports vs NIFs

**Decision**: Use Erlang Ports

**Rationale**:
- Ports provide process isolation - a crashing server doesn't crash the BEAM
- Simpler implementation, no need for C code
- Good enough performance for stdio (not a bottleneck)
- Easier debugging and tracing

**Trade-offs**:
- Slightly higher latency than NIFs
- Extra process for each connection

### HTTP Transport: Req vs HTTPoison/Tesla

**Decision**: Use Req

**Rationale**:
- Modern, functional API with pipelines
- Built on Finch for connection pooling
- First-class support for streaming responses
- Active development and Elixir core team involvement
- Simpler configuration than HTTPoison

**Trade-offs**:
- Newer library, smaller ecosystem
- Requires Elixir 1.12+

### Message Buffering Strategy

**Decision**: Simple binary accumulation with newline splitting

**Rationale**:
- MCP uses newline-delimited JSON (simple protocol)
- Binary operations in Elixir are efficient
- No need for complex framing or length-prefixed messages
- Easy to debug and test

**Alternative Considered**:
- Using a proper streaming JSON parser - rejected as overkill for the protocol

## State Management Decisions

### Request Tracking: ETS vs GenServer State

**Decision**: ETS-backed request tracking

**Rationale**:
- O(1) lookups regardless of pending request count
- Concurrent reads without GenServer bottleneck
- Natural fit for request/response correlation
- Survives GenServer state updates

**Trade-offs**:
- Extra complexity vs simple Map in state
- Need to clean up ETS table on termination

### Connection State Machine

**Decision**: Explicit state machine with atoms (`:disconnected`, `:connecting`, `:initializing`, `:ready`)

**Rationale**:
- MCP has a clear lifecycle that maps to states
- Makes invalid state transitions explicit
- Easy to reason about and test
- Clear logging of state transitions

**Alternative Considered**:
- Using `gen_statem` - rejected as overkill for this simple state machine

## Concurrency Decisions

### Process Architecture

**Decision**: One GenServer per connection

**Rationale**:
- Crash isolation - one bad connection doesn't affect others
- Natural fit for Elixir/OTP supervision
- Easy to scale (just add more connections)
- State encapsulation per connection

### Pool Strategy

**Decision**: DynamicSupervisor with atomics-based round-robin

**Rationale**:
- DynamicSupervisor allows runtime connection add/remove
- Atomics for counter is lock-free
- Round-robin is simple and effective for most cases
- Easy to add other strategies later

**Trade-offs**:
- Not as sophisticated as NimblePool
- No connection health checking (future enhancement)

## API Design Decisions

### Functional API vs Object-Oriented

**Decision**: Functional API with connection as first argument

```elixir
# Our approach
Hermolaos.call_tool(conn, "tool", args)

# Alternative (OOP-style)
conn |> Hermolaos.call_tool("tool", args)
```

**Rationale**:
- Idiomatic Elixir
- Easy to compose with pipes
- Consistent with other Elixir libraries (Ecto, etc.)

### Error Representation

**Decision**: Tagged tuples with custom error struct

```elixir
{:error, %Hermolaos.Error{code: -32601, message: "Method not found"}}
```

**Rationale**:
- Consistent with Elixir conventions
- Preserves full error information from server
- Can be pattern matched on code or message
- Struct provides nice inspection/printing

### Notification Handling

**Decision**: Behaviour-based callbacks

**Rationale**:
- Flexible - users implement what they need
- Optional - can use default handler or ignore
- Testable - easy to mock in tests
- Composable - can chain handlers

**Alternative Considered**:
- Event-based with Registry/PubSub - implemented as optional PubSubNotificationHandler

## Protocol Implementation Decisions

### JSON Library

**Decision**: Jason

**Rationale**:
- De facto standard in Elixir ecosystem
- Excellent performance
- Well-maintained
- Good error messages

### Message Builders

**Decision**: Functions returning maps with `"method"` and `"params"` keys

```elixir
Messages.tools_call("name", %{})
# => %{"method" => "tools/call", "params" => %{"name" => "name", "arguments" => %{}}}
```

**Rationale**:
- Self-describing - includes method name
- Easy to extend with validation later
- Can be used with any transport

### Capability Negotiation

**Decision**: Simple intersection-based matching

**Rationale**:
- MCP capabilities are straightforward
- No complex version negotiation needed
- Easy to extend as MCP evolves

## Testing Decisions

### Mock Server Approach

**Decision**: In-process mock server for protocol testing

**Rationale**:
- Fast - no actual subprocess/HTTP overhead
- Deterministic - no timing issues
- Easy to test edge cases and errors
- Can verify exact protocol compliance

### Test Organization

**Decision**: Separate unit and integration tests

- `test/hermolaos/` - Unit tests per module
- `test/integration/` - End-to-end protocol tests

**Rationale**:
- Unit tests are fast and focused
- Integration tests verify the full stack
- Clear separation of concerns

## Performance Considerations

### Non-Blocking Design

All operations are designed to be non-blocking:

1. **Transport sends** are async (cast + callback)
2. **Request tracking** uses ETS (no GenServer blocking)
3. **Timeout handling** uses Process timers
4. **Pool checkout** is lock-free (atomics counter)

### Memory Efficiency

1. **Binary references** preserved where possible
2. **ETS** for large datasets (request tracking)
3. **Streaming** support for large responses (future)

## Future Considerations

### Potential Enhancements

1. **Connection health checking** - Periodic pings to detect dead connections
2. **Automatic reconnection** - Transparent recovery from transport failures
3. **Request retry** - Automatic retry with backoff for transient errors
4. **Telemetry integration** - Emit telemetry events for monitoring
5. **Connection warm-up** - Pre-establish connections before needed

### Protocol Evolution

The design accommodates MCP protocol evolution:

1. **Version negotiation** during initialization
2. **Capability-based** feature detection
3. **Message builders** can add new methods easily
4. **Error codes** are easily extensible

## References

- [MCP Specification](https://spec.modelcontextprotocol.io)
- [JSON-RPC 2.0 Specification](https://www.jsonrpc.org/specification)
- [Req Documentation](https://hexdocs.pm/req)
- [Erlang Port Documentation](https://www.erlang.org/doc/reference_manual/ports.html)
