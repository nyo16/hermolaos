# Charon

An Elixir client for the [Model Context Protocol (MCP)](https://modelcontextprotocol.io/), enabling communication with AI tools and resources through a standardized protocol.

## Features

- **Two transports**: Stdio (subprocess) and HTTP/SSE (remote servers)
- **Full MCP support**: Tools, resources, prompts, and notifications
- **Connection pooling**: Built-in pool with load balancing strategies
- **Non-blocking**: Async operations with ETS-backed request tracking
- **Extensible**: Custom notification handlers and transport implementations

## Installation

Add `charon` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:charon, "~> 0.1.0"}
  ]
end
```

## Quick Start

### Connecting to a Stdio Server

```elixir
# Connect to a local MCP server via subprocess
{:ok, conn} = Charon.connect(:stdio,
  command: "npx",
  args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
)

# List available tools
{:ok, %{tools: tools}} = Charon.list_tools(conn)

# Call a tool
{:ok, result} = Charon.call_tool(conn, "read_file", %{path: "/tmp/test.txt"})

# Disconnect when done
:ok = Charon.disconnect(conn)
```

### Connecting to an HTTP Server

```elixir
# Connect to a remote MCP server via HTTP
{:ok, conn} = Charon.connect(:http,
  url: "http://localhost:3000/mcp"
)

# Use the same API as stdio
{:ok, %{tools: tools}} = Charon.list_tools(conn)
```

## API Reference

### Connection Management

```elixir
# Connect with options
{:ok, conn} = Charon.connect(:stdio, command: "server", args: ["--flag"])
{:ok, conn} = Charon.connect(:http, url: "http://localhost:3000/mcp")

# Disconnect
:ok = Charon.disconnect(conn)

# Health check
{:ok, %{}} = Charon.ping(conn)

# Get connection status
:ready = Charon.status(conn)
```

### Tools

```elixir
# List all available tools
{:ok, %{tools: tools}} = Charon.list_tools(conn)

# Call a tool with arguments
{:ok, result} = Charon.call_tool(conn, "tool_name", %{arg1: "value"})

# With custom timeout
{:ok, result} = Charon.call_tool(conn, "slow_tool", %{}, timeout: 60_000)

# Extract text from result
text = Charon.get_text(result)

# Extract image from result (returns decoded binary)
{:ok, image_data} = Charon.get_image(result)
File.write!("output.png", image_data)
```

### Resources

```elixir
# List available resources
{:ok, %{resources: resources}} = Charon.list_resources(conn)

# Read a specific resource
{:ok, %{contents: contents}} = Charon.read_resource(conn, "file:///path/to/file")
```

### Prompts

```elixir
# List available prompts
{:ok, %{prompts: prompts}} = Charon.list_prompts(conn)

# Get a prompt with arguments
{:ok, %{messages: messages}} = Charon.get_prompt(conn, "prompt_name", %{arg: "value"})
```

## Connection Options

### Stdio Transport

```elixir
Charon.connect(:stdio,
  command: "path/to/server",    # Required: executable path
  args: ["--flag", "value"],    # Optional: command line arguments
  env: %{"VAR" => "value"},     # Optional: environment variables
  timeout: 30_000               # Optional: request timeout (default: 30s)
)
```

### HTTP Transport

```elixir
Charon.connect(:http,
  url: "http://localhost:3000/mcp",  # Required: server URL
  headers: [{"Authorization", "Bearer token"}],  # Optional: custom headers
  timeout: 30_000                     # Optional: request timeout
)
```

## Connection Pooling

For high-throughput scenarios, use the built-in connection pool:

```elixir
# Start a pool with multiple connections
{:ok, pool} = Charon.Pool.start_link(
  name: MyApp.MCPPool,
  size: 4,
  connection_opts: [
    transport: :stdio,
    command: "my-server"
  ],
  strategy: :round_robin  # or :random, :least_busy
)

# Use checkout/checkin pattern
{:ok, conn} = Charon.Pool.checkout(MyApp.MCPPool)
result = Charon.call_tool(conn, "my_tool", %{})
Charon.Pool.checkin(MyApp.MCPPool, conn)

# Or use transaction for automatic checkin
result = Charon.Pool.transaction(MyApp.MCPPool, fn conn ->
  Charon.call_tool(conn, "my_tool", %{})
end)
```

## Notification Handling

Handle server notifications with custom handlers:

```elixir
defmodule MyApp.MCPHandler do
  @behaviour Charon.Client.NotificationHandler

  @impl true
  def handle_notification({:notification, "notifications/tools/list_changed", _}, state) do
    IO.puts("Tools list changed!")
    {:ok, state}
  end

  def handle_notification(_event, state), do: {:ok, state}
end

# Use custom handler
{:ok, conn} = Charon.connect(:stdio,
  command: "server",
  notification_handler: {MyApp.MCPHandler, %{}}
)
```

## Error Handling

Errors are returned as `{:error, %Charon.Error{}}`:

```elixir
case Charon.call_tool(conn, "unknown_tool", %{}) do
  {:ok, result} ->
    # Handle success
    result

  {:error, %Charon.Error{code: -32601, message: message}} ->
    # Method not found
    Logger.error("Tool not found: #{message}")

  {:error, %Charon.Error{code: -32001}} ->
    # Request timeout
    Logger.error("Request timed out")

  {:error, error} ->
    # Other error
    Logger.error("Error: #{inspect(error)}")
end
```

## Example: Playwright Browser Automation

Charon works with browser automation MCP servers like [Playwright MCP](https://github.com/microsoft/playwright-mcp):

```elixir
# Connect to Playwright MCP server
{:ok, conn} = Charon.connect(:stdio,
  command: "npx",
  args: ["@playwright/mcp@latest"]
)

# Navigate to a page
Charon.call_tool(conn, "browser_navigate", %{"url" => "https://example.com"})

# Get page snapshot (accessibility tree with element refs)
{:ok, snap} = Charon.call_tool(conn, "browser_snapshot", %{})
IO.puts(Charon.get_text(snap))

# Click an element (use ref from snapshot)
Charon.call_tool(conn, "browser_click", %{"element" => "More information", "ref" => "e5"})

# Take a screenshot
{:ok, result} = Charon.call_tool(conn, "browser_take_screenshot", %{})
{:ok, image} = Charon.get_image(result)
File.write!("screenshot.png", image)

# Close and disconnect
Charon.call_tool(conn, "browser_close", %{})
Charon.disconnect(conn)
```

## Architecture

See [docs/architecture.md](docs/architecture.md) for detailed architecture documentation.

## Design Decisions

See [docs/design_decisions.md](docs/design_decisions.md) for rationale behind key design choices.

## Testing

```bash
# Run all tests
mix test

# Run with coverage
mix test --cover
```

## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b feature/my-feature`)
3. Commit your changes (`git commit -am 'Add my feature'`)
4. Push to the branch (`git push origin feature/my-feature`)
5. Create a Pull Request

## License

MIT License - see LICENSE file for details.

## References

- [MCP Specification](https://spec.modelcontextprotocol.io)
- [MCP Documentation](https://modelcontextprotocol.io/docs)
- [JSON-RPC 2.0 Specification](https://www.jsonrpc.org/specification)
