<p align="center">
  <img src="images/header.jpeg" alt="Hermolaos - An Elixir client for the Model Context Protocol (MCP)" width="100%">
</p>

<p align="center">
  <a href="https://hex.pm/packages/hermolaos"><img src="https://img.shields.io/hexpm/v/hermolaos.svg" alt="Hex.pm"></a>
  <a href="https://hexdocs.pm/hermolaos"><img src="https://img.shields.io/badge/hex-docs-blue.svg" alt="Docs"></a>
  <a href="LICENSE"><img src="https://img.shields.io/hexpm/l/hermolaos.svg" alt="License"></a>
</p>

An Elixir client for the [Model Context Protocol (MCP)](https://modelcontextprotocol.io/), enabling communication with AI tools and resources through a standardized protocol.

## Features

- **Two transports**: Stdio (subprocess) and HTTP/SSE (remote servers)
- **Full MCP support**: Tools, resources, prompts, and notifications
- **Connection pooling**: Built-in pool with load balancing strategies
- **Non-blocking**: Async operations with ETS-backed request tracking
- **Extensible**: Custom notification handlers and transport implementations

## Requirements

- **Elixir** >= 1.14
- **Erlang/OTP** >= 25
- **Node.js** >= 18 (only for stdio transport with npm-based MCP servers)

## Installation

Add `hermolaos` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:hermolaos, "~> 0.3.0"}
  ]
end
```

## Quick Start

### Connecting to a Stdio Server

```elixir
# Connect to a local MCP server via subprocess
{:ok, conn} = Hermolaos.connect(:stdio,
  command: "npx",
  args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
)

# List available tools
{:ok, %{tools: tools}} = Hermolaos.list_tools(conn)

# Call a tool
{:ok, result} = Hermolaos.call_tool(conn, "read_file", %{path: "/tmp/test.txt"})

# Disconnect when done
:ok = Hermolaos.disconnect(conn)
```

### Connecting to an HTTP Server

```elixir
# Connect to a remote MCP server via HTTP
{:ok, conn} = Hermolaos.connect(:http,
  url: "http://localhost:3000/mcp"
)

# Use the same API as stdio
{:ok, %{tools: tools}} = Hermolaos.list_tools(conn)
```

## API Reference

### Connection Management

```elixir
# Connect with options
{:ok, conn} = Hermolaos.connect(:stdio, command: "server", args: ["--flag"])
{:ok, conn} = Hermolaos.connect(:http, url: "http://localhost:3000/mcp")

# Disconnect
:ok = Hermolaos.disconnect(conn)

# Health check
{:ok, %{}} = Hermolaos.ping(conn)

# Get connection status
:ready = Hermolaos.status(conn)
```

### Tools

```elixir
# List all available tools
{:ok, %{tools: tools}} = Hermolaos.list_tools(conn)

# Call a tool with arguments
{:ok, result} = Hermolaos.call_tool(conn, "tool_name", %{arg1: "value"})

# With custom timeout
{:ok, result} = Hermolaos.call_tool(conn, "slow_tool", %{}, timeout: 60_000)

# Extract text from result
text = Hermolaos.get_text(result)

# Extract image from result (returns decoded binary)
{:ok, image_data} = Hermolaos.get_image(result)
File.write!("output.png", image_data)
```

### Resources

```elixir
# List available resources
{:ok, %{resources: resources}} = Hermolaos.list_resources(conn)

# Read a specific resource
{:ok, %{contents: contents}} = Hermolaos.read_resource(conn, "file:///path/to/file")
```

### Prompts

```elixir
# List available prompts
{:ok, %{prompts: prompts}} = Hermolaos.list_prompts(conn)

# Get a prompt with arguments
{:ok, %{messages: messages}} = Hermolaos.get_prompt(conn, "prompt_name", %{arg: "value"})
```

## Connection Options

### Stdio Transport

```elixir
Hermolaos.connect(:stdio,
  command: "path/to/server",    # Required: executable path
  args: ["--flag", "value"],    # Optional: command line arguments
  env: %{"VAR" => "value"},     # Optional: environment variables
  timeout: 30_000               # Optional: request timeout (default: 30s)
)
```

### HTTP Transport

```elixir
Hermolaos.connect(:http,
  url: "http://localhost:3000/mcp",  # Required: server URL
  headers: [{"authorization", "Bearer token"}],  # Optional: custom headers
  timeout: 30_000                     # Optional: request timeout
)
```

### Authentication

For MCP servers requiring authentication, pass headers with your credentials:

```elixir
# Bearer token authentication
{:ok, conn} = Hermolaos.connect(:http,
  url: "https://api.example.com/mcp",
  headers: [{"authorization", "Bearer your-jwt-token"}]
)

# API key authentication
{:ok, conn} = Hermolaos.connect(:http,
  url: "https://api.example.com/mcp",
  headers: [{"x-api-key", "your-api-key"}]
)

# Multiple headers
{:ok, conn} = Hermolaos.connect(:http,
  url: "https://api.example.com/mcp",
  headers: [
    {"authorization", "Bearer token"},
    {"x-api-key", "key"},
    {"x-custom-header", "value"}
  ]
)
```

## Connection Pooling

For high-throughput scenarios, use the built-in connection pool:

```elixir
# Start a pool with multiple connections
{:ok, pool} = Hermolaos.Pool.start_link(
  name: MyApp.MCPPool,
  size: 4,
  connection_opts: [
    transport: :stdio,
    command: "my-server"
  ],
  strategy: :round_robin  # or :random, :least_busy
)

# Use checkout/checkin pattern
{:ok, conn} = Hermolaos.Pool.checkout(MyApp.MCPPool)
result = Hermolaos.call_tool(conn, "my_tool", %{})
Hermolaos.Pool.checkin(MyApp.MCPPool, conn)

# Or use transaction for automatic checkin
result = Hermolaos.Pool.transaction(MyApp.MCPPool, fn conn ->
  Hermolaos.call_tool(conn, "my_tool", %{})
end)
```

## Notification Handling

Handle server notifications with custom handlers:

```elixir
defmodule MyApp.MCPHandler do
  @behaviour Hermolaos.Client.NotificationHandler

  @impl true
  def handle_notification({:notification, "notifications/tools/list_changed", _}, state) do
    IO.puts("Tools list changed!")
    {:ok, state}
  end

  def handle_notification(_event, state), do: {:ok, state}
end

# Use custom handler
{:ok, conn} = Hermolaos.connect(:stdio,
  command: "server",
  notification_handler: {MyApp.MCPHandler, %{}}
)
```

## Error Handling

Errors are returned as `{:error, %Hermolaos.Error{}}`:

```elixir
case Hermolaos.call_tool(conn, "unknown_tool", %{}) do
  {:ok, result} ->
    # Handle success
    result

  {:error, %Hermolaos.Error{code: -32601, message: message}} ->
    # Method not found
    Logger.error("Tool not found: #{message}")

  {:error, %Hermolaos.Error{code: -32001}} ->
    # Request timeout
    Logger.error("Request timed out")

  {:error, error} ->
    # Other error
    Logger.error("Error: #{inspect(error)}")
end
```

## Example: Playwright Browser Automation

Hermolaos works with browser automation MCP servers like [Playwright MCP](https://github.com/microsoft/playwright-mcp):

```elixir
# Connect to Playwright MCP server
{:ok, conn} = Hermolaos.connect(:stdio,
  command: "npx",
  args: ["@playwright/mcp@latest"]
)

# Navigate to a page
Hermolaos.call_tool(conn, "browser_navigate", %{"url" => "https://example.com"})

# Get page snapshot (accessibility tree with element refs)
{:ok, snap} = Hermolaos.call_tool(conn, "browser_snapshot", %{})
IO.puts(Hermolaos.get_text(snap))

# Click an element (use ref from snapshot)
Hermolaos.call_tool(conn, "browser_click", %{"element" => "More information", "ref" => "e5"})

# Take a screenshot
{:ok, result} = Hermolaos.call_tool(conn, "browser_take_screenshot", %{})
{:ok, image} = Hermolaos.get_image(result)
File.write!("screenshot.png", image)

# Close and disconnect
Hermolaos.call_tool(conn, "browser_close", %{})
Hermolaos.disconnect(conn)
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

# Run Playwright integration tests (requires Node.js)
mix test --include playwright
```

### Running Playwright Tests in Docker (Headless)

For CI/CD or headless environments, you can run Playwright tests in Docker:

```dockerfile
# Dockerfile.test
FROM mcr.microsoft.com/playwright:v1.40.0-jammy

# Install Erlang and Elixir
RUN apt-get update && apt-get install -y \
    erlang \
    elixir \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY . .

RUN mix local.hex --force && mix local.rebar --force
RUN mix deps.get
RUN mix compile

# Run tests with Playwright
CMD ["mix", "test", "--include", "playwright"]
```

Or use docker-compose:

```yaml
# docker-compose.test.yml
version: '3.8'
services:
  test:
    build:
      context: .
      dockerfile: Dockerfile.test
    environment:
      - MIX_ENV=test
      - PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
```

Run with:

```bash
docker-compose -f docker-compose.test.yml up --build
```

**Note:** The `mcr.microsoft.com/playwright` image includes all browser dependencies pre-installed for headless execution.

## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b feature/my-feature`)
3. Commit your changes (`git commit -am 'Add my feature'`)
4. Push to the branch (`git push origin feature/my-feature`)
5. Create a Pull Request

## License

Apache License 2.0 - see [LICENSE](LICENSE) file for details.

## References

- [MCP Specification](https://spec.modelcontextprotocol.io)
- [MCP Documentation](https://modelcontextprotocol.io/docs)
- [JSON-RPC 2.0 Specification](https://www.jsonrpc.org/specification)
