defmodule Hermolaos.Client.RequestTracker do
  @moduledoc """
  Tracks pending JSON-RPC requests and correlates them with responses.

  The RequestTracker maintains a mapping of request IDs to caller information,
  enabling the Connection to route responses back to the correct caller.

  ## Features

  - Monotonically increasing integer IDs for efficiency
  - ETS-backed storage for O(1) lookups and concurrent access
  - Automatic timeout handling with configurable defaults
  - Statistics tracking for monitoring

  ## Design Notes

  This module uses ETS for storage because:

  1. **Performance**: O(1) lookups regardless of pending request count
  2. **Concurrency**: ETS tables support concurrent reads without locking
  3. **Isolation**: Each tracker has its own table, crashes don't affect others

  ## Example

      {:ok, tracker} = Hermolaos.Client.RequestTracker.start_link(timeout: 30_000)

      # Track a request
      id = Hermolaos.Client.RequestTracker.next_id(tracker)
      :ok = Hermolaos.Client.RequestTracker.track(tracker, id, "tools/list", from)

      # When response arrives, complete the request
      {:ok, from, method} = Hermolaos.Client.RequestTracker.complete(tracker, id)
      GenServer.reply(from, result)
  """

  use GenServer
  require Logger

  alias Hermolaos.Protocol.Errors

  # ============================================================================
  # Type Definitions
  # ============================================================================

  @type t :: GenServer.server()
  @type id :: integer()
  @type method :: String.t()
  @type from :: GenServer.from()

  @type pending_request :: %{
          method: method(),
          from: from(),
          timeout_ref: reference() | nil,
          started_at: integer()
        }

  @type stats :: %{
          requests_tracked: non_neg_integer(),
          requests_completed: non_neg_integer(),
          requests_failed: non_neg_integer(),
          requests_timed_out: non_neg_integer(),
          requests_cancelled: non_neg_integer()
        }

  @default_timeout 30_000

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Starts a new request tracker.

  ## Options

  - `:timeout` - Default timeout for requests in ms (default: 30000)
  - `:name` - GenServer name (optional)

  ## Examples

      {:ok, tracker} = Hermolaos.Client.RequestTracker.start_link()
      {:ok, tracker} = Hermolaos.Client.RequestTracker.start_link(timeout: 60_000)
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Gets the next request ID (monotonically increasing integer).

  ## Examples

      id = Hermolaos.Client.RequestTracker.next_id(tracker)
      # => 1

      id = Hermolaos.Client.RequestTracker.next_id(tracker)
      # => 2
  """
  @spec next_id(t()) :: id()
  def next_id(tracker) do
    GenServer.call(tracker, :next_id)
  end

  @doc """
  Tracks a pending request.

  ## Parameters

  - `tracker` - The tracker process
  - `id` - Request ID (from `next_id/1`)
  - `method` - JSON-RPC method name
  - `from` - GenServer from tuple for reply
  - `timeout` - Optional timeout override in ms

  ## Examples

      :ok = Hermolaos.Client.RequestTracker.track(tracker, 1, "tools/list", from)
      :ok = Hermolaos.Client.RequestTracker.track(tracker, 2, "tools/call", from, 60_000)
  """
  @spec track(t(), id(), method(), from(), timeout() | nil) :: :ok
  def track(tracker, id, method, from, timeout \\ nil) do
    GenServer.call(tracker, {:track, id, method, from, timeout})
  end

  @doc """
  Completes a pending request successfully.

  Returns the original caller's `from` and method so the caller can be notified.

  ## Examples

      case Hermolaos.Client.RequestTracker.complete(tracker, 1) do
        {:ok, from, "tools/list"} ->
          GenServer.reply(from, {:ok, result})

        {:error, :not_found} ->
          # Request already completed, timed out, or never existed
          :ok
      end
  """
  @spec complete(t(), id()) :: {:ok, from(), method()} | {:error, :not_found}
  def complete(tracker, id) do
    GenServer.call(tracker, {:complete, id})
  end

  @doc """
  Fails a pending request with an error.

  ## Examples

      case Hermolaos.Client.RequestTracker.fail(tracker, 1, error) do
        {:ok, from, method} ->
          GenServer.reply(from, {:error, error})

        {:error, :not_found} ->
          :ok
      end
  """
  @spec fail(t(), id(), term()) :: {:ok, from(), method()} | {:error, :not_found}
  def fail(tracker, id, _error) do
    GenServer.call(tracker, {:fail, id})
  end

  @doc """
  Cancels a pending request.

  ## Examples

      :ok = Hermolaos.Client.RequestTracker.cancel(tracker, 1)
  """
  @spec cancel(t(), id()) :: :ok
  def cancel(tracker, id) do
    GenServer.call(tracker, {:cancel, id})
  end

  @doc """
  Fails all pending requests (e.g., when connection closes).

  Returns the list of failed requests with their callers.

  ## Examples

      failed = Hermolaos.Client.RequestTracker.fail_all(tracker, {:error, :connection_closed})
      for {from, method} <- failed do
        GenServer.reply(from, {:error, :connection_closed})
      end
  """
  @spec fail_all(t(), term()) :: [{from(), method()}]
  def fail_all(tracker, _error) do
    GenServer.call(tracker, :fail_all)
  end

  @doc """
  Returns the number of pending requests.

  ## Examples

      count = Hermolaos.Client.RequestTracker.pending_count(tracker)
      # => 5
  """
  @spec pending_count(t()) :: non_neg_integer()
  def pending_count(tracker) do
    GenServer.call(tracker, :pending_count)
  end

  @doc """
  Returns tracker statistics.

  ## Examples

      stats = Hermolaos.Client.RequestTracker.stats(tracker)
      # => %{requests_tracked: 100, requests_completed: 95, ...}
  """
  @spec stats(t()) :: stats()
  def stats(tracker) do
    GenServer.call(tracker, :stats)
  end

  @doc """
  Checks if a request ID is currently pending.
  """
  @spec pending?(t(), id()) :: boolean()
  def pending?(tracker, id) do
    GenServer.call(tracker, {:pending?, id})
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl GenServer
  def init(opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    # Create ETS table for O(1) lookups
    table = :ets.new(:request_tracker, [:set, :private])

    state = %{
      table: table,
      next_id: 1,
      default_timeout: timeout,
      stats: %{
        requests_tracked: 0,
        requests_completed: 0,
        requests_failed: 0,
        requests_timed_out: 0,
        requests_cancelled: 0
      }
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:next_id, _from, state) do
    id = state.next_id
    {:reply, id, %{state | next_id: id + 1}}
  end

  @impl GenServer
  def handle_call({:track, id, method, from, timeout_override}, _from, state) do
    timeout = timeout_override || state.default_timeout

    # Start timeout timer
    timeout_ref = Process.send_after(self(), {:timeout, id}, timeout)

    request = %{
      method: method,
      from: from,
      timeout_ref: timeout_ref,
      started_at: System.monotonic_time(:millisecond)
    }

    :ets.insert(state.table, {id, request})

    new_stats = Map.update!(state.stats, :requests_tracked, &(&1 + 1))
    {:reply, :ok, %{state | stats: new_stats}}
  end

  @impl GenServer
  def handle_call({:complete, id}, _from, state) do
    case :ets.lookup(state.table, id) do
      [{^id, request}] ->
        :ets.delete(state.table, id)
        cancel_timeout(request.timeout_ref)

        new_stats = Map.update!(state.stats, :requests_completed, &(&1 + 1))
        {:reply, {:ok, request.from, request.method}, %{state | stats: new_stats}}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl GenServer
  def handle_call({:fail, id}, _from, state) do
    case :ets.lookup(state.table, id) do
      [{^id, request}] ->
        :ets.delete(state.table, id)
        cancel_timeout(request.timeout_ref)

        new_stats = Map.update!(state.stats, :requests_failed, &(&1 + 1))
        {:reply, {:ok, request.from, request.method}, %{state | stats: new_stats}}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl GenServer
  def handle_call({:cancel, id}, _from, state) do
    case :ets.lookup(state.table, id) do
      [{^id, request}] ->
        :ets.delete(state.table, id)
        cancel_timeout(request.timeout_ref)

        new_stats = Map.update!(state.stats, :requests_cancelled, &(&1 + 1))
        {:reply, :ok, %{state | stats: new_stats}}

      [] ->
        {:reply, :ok, state}
    end
  end

  @impl GenServer
  def handle_call(:fail_all, _from, state) do
    requests = :ets.tab2list(state.table)

    failed =
      for {id, request} <- requests do
        :ets.delete(state.table, id)
        cancel_timeout(request.timeout_ref)
        {request.from, request.method}
      end

    new_stats = Map.update!(state.stats, :requests_failed, &(&1 + length(failed)))
    {:reply, failed, %{state | stats: new_stats}}
  end

  @impl GenServer
  def handle_call(:pending_count, _from, state) do
    count = :ets.info(state.table, :size)
    {:reply, count, state}
  end

  @impl GenServer
  def handle_call(:stats, _from, state) do
    {:reply, state.stats, state}
  end

  @impl GenServer
  def handle_call({:pending?, id}, _from, state) do
    result = :ets.member(state.table, id)
    {:reply, result, state}
  end

  @impl GenServer
  def handle_info({:timeout, id}, state) do
    case :ets.lookup(state.table, id) do
      [{^id, request}] ->
        :ets.delete(state.table, id)
        Logger.debug("[RequestTracker] Request #{id} (#{request.method}) timed out")

        # Reply with timeout error
        error = Errors.request_timeout(request.method)
        GenServer.reply(request.from, {:error, error})

        new_stats = Map.update!(state.stats, :requests_timed_out, &(&1 + 1))
        {:noreply, %{state | stats: new_stats}}

      [] ->
        # Already completed/failed
        {:noreply, state}
    end
  end

  @impl GenServer
  def terminate(_reason, state) do
    :ets.delete(state.table)
    :ok
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp cancel_timeout(nil), do: :ok

  defp cancel_timeout(ref) do
    Process.cancel_timer(ref)
    :ok
  end
end
