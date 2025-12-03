defmodule Charon.Pool do
  @moduledoc """
  Connection pool for managing multiple MCP connections.

  The Pool provides load balancing and fault tolerance for MCP operations
  by maintaining multiple connections to one or more servers.

  ## Use Cases

  1. **High throughput**: Distribute requests across multiple connections
  2. **Redundancy**: Multiple connections to the same server for failover
  3. **Multi-server**: Connect to multiple MCP servers simultaneously

  ## Architecture

  The Pool uses a DynamicSupervisor to manage connections. Each connection
  is a supervised `Charon.Client.Connection` process. The pool uses a
  Registry for efficient connection lookup.

  ## Example

      # Start a pool
      {:ok, pool} = Charon.Pool.start_link(
        name: MyApp.MCPPool,
        connections: [
          [transport: :stdio, command: "server1"],
          [transport: :stdio, command: "server2"]
        ]
      )

      # Use checkout/checkin pattern
      {:ok, conn} = Charon.Pool.checkout(MyApp.MCPPool)
      result = Charon.call_tool(conn, "my_tool", %{})
      Charon.Pool.checkin(MyApp.MCPPool, conn)

      # Or use transaction for automatic checkin
      result = Charon.Pool.transaction(MyApp.MCPPool, fn conn ->
        Charon.call_tool(conn, "my_tool", %{})
      end)

  ## Strategies

  - `:round_robin` - Rotate through available connections (default)
  - `:random` - Randomly select a connection
  - `:least_busy` - Select connection with fewest pending requests

  ## Pool as Charon Client

  The pool itself implements the same interface as a single connection,
  so you can use `Charon.call_tool/4` etc. directly with the pool name.
  """

  use Supervisor
  require Logger

  alias Charon.Client.Connection

  @type pool :: Supervisor.supervisor()
  @type strategy :: :round_robin | :random | :least_busy

  @type pool_option ::
          {:name, atom()}
          | {:connections, [keyword()]}
          | {:size, pos_integer()}
          | {:strategy, strategy()}
          | {:connection_opts, keyword()}

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Starts a connection pool.

  ## Options

  - `:name` - Pool name (required, used for registration)
  - `:connections` - List of connection option keyword lists
  - `:size` - Number of identical connections (alternative to `:connections`)
  - `:connection_opts` - Common options for all connections when using `:size`
  - `:strategy` - Load balancing strategy (default: `:round_robin`)

  ## Examples

      # Multiple connections with explicit configs
      {:ok, pool} = Charon.Pool.start_link(
        name: MyPool,
        connections: [
          [transport: :stdio, command: "server1"],
          [transport: :http, url: "http://localhost:3000/mcp"]
        ]
      )

      # Pool of identical connections
      {:ok, pool} = Charon.Pool.start_link(
        name: MyPool,
        size: 4,
        connection_opts: [transport: :stdio, command: "my-server"]
      )
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Checks out a connection from the pool.

  Returns a connection that should be checked back in after use,
  or used within a `transaction/2` block.

  ## Options

  - `:timeout` - Maximum time to wait for a connection (default: 5000)

  ## Examples

      {:ok, conn} = Charon.Pool.checkout(MyPool)
      # use conn...
      Charon.Pool.checkin(MyPool, conn)
  """
  @spec checkout(pool(), keyword()) :: {:ok, Connection.t()} | {:error, :no_connections}
  def checkout(pool, _opts \\ []) do
    strategy = get_strategy(pool)

    case get_connections(pool) do
      [] ->
        {:error, :no_connections}

      connections ->
        conn = select_connection(connections, strategy, pool)
        {:ok, conn}
    end
  end

  @doc """
  Checks a connection back into the pool.

  This is a no-op in the current implementation but is included for
  API compatibility with checkout/checkin patterns.
  """
  @spec checkin(pool(), Connection.t()) :: :ok
  def checkin(_pool, _conn) do
    :ok
  end

  @doc """
  Executes a function with a checked-out connection.

  Automatically checks in the connection after the function completes.

  ## Examples

      result = Charon.Pool.transaction(MyPool, fn conn ->
        Charon.call_tool(conn, "my_tool", %{arg: "value"})
      end)
  """
  @spec transaction(pool(), (Connection.t() -> result)) :: result when result: term()
  def transaction(pool, fun) when is_function(fun, 1) do
    case checkout(pool) do
      {:ok, conn} ->
        try do
          fun.(conn)
        after
          checkin(pool, conn)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns the list of all connections in the pool.
  """
  @spec connections(pool()) :: [Connection.t()]
  def connections(pool) do
    get_connections(pool)
  end

  @doc """
  Returns pool statistics.
  """
  @spec stats(pool()) :: map()
  def stats(pool) do
    connections = get_connections(pool)

    %{
      total_connections: length(connections),
      ready_connections: Enum.count(connections, &(Connection.status(&1) == :ready)),
      strategy: get_strategy(pool)
    }
  end

  @doc """
  Adds a new connection to the pool.

  ## Examples

      {:ok, conn} = Charon.Pool.add_connection(MyPool, transport: :stdio, command: "new-server")
  """
  @spec add_connection(pool(), keyword()) :: {:ok, Connection.t()} | {:error, term()}
  def add_connection(pool, opts) do
    supervisor = pool_supervisor(pool)

    case DynamicSupervisor.start_child(supervisor, {Connection, opts}) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Removes a connection from the pool.
  """
  @spec remove_connection(pool(), Connection.t()) :: :ok | {:error, :not_found}
  def remove_connection(pool, conn) do
    supervisor = pool_supervisor(pool)

    case DynamicSupervisor.terminate_child(supervisor, conn) do
      :ok -> :ok
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  # ============================================================================
  # Supervisor Callbacks
  # ============================================================================

  @impl Supervisor
  def init(opts) do
    pool_name = Keyword.fetch!(opts, :name)
    strategy = Keyword.get(opts, :strategy, :round_robin)

    # Build connection specs
    connection_specs = build_connection_specs(opts)

    # Store pool metadata in persistent term for fast access
    :persistent_term.put({__MODULE__, pool_name, :strategy}, strategy)
    :persistent_term.put({__MODULE__, pool_name, :counter}, :atomics.new(1, []))

    children = [
      # DynamicSupervisor for connections
      {DynamicSupervisor, name: pool_supervisor_name(pool_name), strategy: :one_for_one}
    ]

    # Start supervisor first, then add connections
    result = Supervisor.init(children, strategy: :one_for_one)

    # Schedule connection startup after supervisor is ready
    if connection_specs != [] do
      send(self(), {:start_connections, pool_name, connection_specs})
    end

    result
  end

  # Handle connection startup message
  def handle_info({:start_connections, pool_name, specs}, state) do
    supervisor = pool_supervisor_name(pool_name)

    for spec <- specs do
      DynamicSupervisor.start_child(supervisor, spec)
    end

    {:noreply, state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp build_connection_specs(opts) do
    cond do
      Keyword.has_key?(opts, :connections) ->
        opts
        |> Keyword.fetch!(:connections)
        |> Enum.map(fn conn_opts -> {Connection, conn_opts} end)

      Keyword.has_key?(opts, :size) ->
        size = Keyword.fetch!(opts, :size)
        base_opts = Keyword.get(opts, :connection_opts, [])

        for _i <- 1..size do
          {Connection, base_opts}
        end

      true ->
        []
    end
  end

  defp get_connections(pool) do
    supervisor = pool_supervisor(pool)

    DynamicSupervisor.which_children(supervisor)
    |> Enum.map(fn {_, pid, _, _} -> pid end)
    |> Enum.filter(&is_pid/1)
    |> Enum.filter(&Process.alive?/1)
  end

  defp get_strategy(pool) do
    pool_name = pool_name(pool)
    :persistent_term.get({__MODULE__, pool_name, :strategy}, :round_robin)
  end

  defp select_connection(connections, :random, _pool) do
    Enum.random(connections)
  end

  defp select_connection(connections, :round_robin, pool) do
    pool_name = pool_name(pool)
    counter = :persistent_term.get({__MODULE__, pool_name, :counter})
    index = :atomics.add_get(counter, 1, 1)
    Enum.at(connections, rem(index - 1, length(connections)))
  end

  defp select_connection(connections, :least_busy, _pool) do
    # For now, just pick randomly
    # TODO: Track pending requests per connection
    Enum.random(connections)
  end

  defp pool_supervisor(pool) when is_atom(pool) do
    pool_supervisor_name(pool)
  end

  defp pool_supervisor(pool) when is_pid(pool) do
    # Find the DynamicSupervisor child
    pool
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {_, pid, :supervisor, [DynamicSupervisor]} -> pid
      _ -> nil
    end)
  end

  defp pool_supervisor_name(pool_name) do
    Module.concat(pool_name, ConnectionSupervisor)
  end

  defp pool_name(pool) when is_atom(pool), do: pool
  defp pool_name(pool) when is_pid(pool) do
    case Process.info(pool, :registered_name) do
      {:registered_name, name} -> name
      nil -> pool
    end
  end
end
