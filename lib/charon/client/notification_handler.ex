defmodule Charon.Client.NotificationHandler do
  @moduledoc """
  Behaviour for handling MCP server notifications and requests.

  When a server sends notifications (like list_changed events) or requests
  (like ping or sampling), they are dispatched to a notification handler
  if one is configured.

  ## Implementing a Handler

      defmodule MyApp.MCPHandler do
        @behaviour Charon.Client.NotificationHandler

        @impl true
        def handle_notification({:notification, "notifications/tools/list_changed", _params}, state) do
          IO.puts("Tools list changed!")
          {:ok, state}
        end

        def handle_notification({:notification, method, params}, state) do
          IO.puts("Got notification: \#{method}")
          {:ok, state}
        end

        def handle_notification({:request, "ping", _params}, state) do
          # ping is handled automatically, but you can observe it
          {:ok, state}
        end

        def handle_notification(_event, state) do
          {:ok, state}
        end
      end

  ## Using the Handler

      {:ok, conn} = Charon.Client.Connection.start_link(
        transport: :stdio,
        command: "my-server",
        notification_handler: {MyApp.MCPHandler, %{}}
      )

  ## Event Types

  Events are tuples with one of these formats:

  - `{:notification, method, params}` - Server notification
  - `{:request, method, params}` - Server request (ping, sampling, etc.)

  ## Common Notifications

  - `notifications/tools/list_changed` - Available tools changed
  - `notifications/resources/list_changed` - Available resources changed
  - `notifications/resources/updated` - A specific resource was updated
  - `notifications/prompts/list_changed` - Available prompts changed
  - `notifications/progress` - Progress update for long operation
  - `notifications/message` - Log message from server
  """

  @type event ::
          {:notification, String.t(), map() | nil}
          | {:request, String.t(), map() | nil}

  @type handler_state :: term()

  @doc """
  Called when a server notification or request is received.

  ## Parameters

  - `event` - The event tuple
  - `state` - Handler state (or nil if no state was provided)

  ## Returns

  - `{:ok, new_state}` - Continue with updated state
  - `:ok` - Continue with unchanged state (convenience for stateless handlers)
  """
  @callback handle_notification(event :: event(), state :: handler_state()) ::
              {:ok, handler_state()} | :ok

  @optional_callbacks []
end

defmodule Charon.Client.DefaultNotificationHandler do
  @moduledoc """
  Default notification handler that logs events.

  This handler is useful for debugging and as a reference implementation.

  ## Usage

      {:ok, conn} = Charon.Client.Connection.start_link(
        transport: :stdio,
        command: "my-server",
        notification_handler: Charon.Client.DefaultNotificationHandler
      )
  """

  @behaviour Charon.Client.NotificationHandler

  require Logger

  @impl true
  def handle_notification({:notification, "notifications/progress", params}, state) do
    token = params["progressToken"]
    progress = params["progress"]
    total = params["total"]

    if total do
      Logger.debug("[MCP Progress] #{token}: #{progress}/#{total}")
    else
      Logger.debug("[MCP Progress] #{token}: #{progress}")
    end

    {:ok, state}
  end

  def handle_notification({:notification, "notifications/message", params}, state) do
    level = params["level"] || "info"
    message = params["data"]
    logger = params["logger"]

    prefix = if logger, do: "[#{logger}] ", else: ""

    case level do
      "debug" -> Logger.debug("#{prefix}#{message}")
      "info" -> Logger.info("#{prefix}#{message}")
      "notice" -> Logger.info("#{prefix}#{message}")
      "warning" -> Logger.warning("#{prefix}#{message}")
      "error" -> Logger.error("#{prefix}#{message}")
      "critical" -> Logger.error("[CRITICAL] #{prefix}#{message}")
      "alert" -> Logger.error("[ALERT] #{prefix}#{message}")
      "emergency" -> Logger.error("[EMERGENCY] #{prefix}#{message}")
      _ -> Logger.info("#{prefix}#{message}")
    end

    {:ok, state}
  end

  def handle_notification({:notification, "notifications/tools/list_changed", _params}, state) do
    Logger.info("[MCP] Server tools list changed")
    {:ok, state}
  end

  def handle_notification({:notification, "notifications/resources/list_changed", _params}, state) do
    Logger.info("[MCP] Server resources list changed")
    {:ok, state}
  end

  def handle_notification({:notification, "notifications/resources/updated", params}, state) do
    uri = params["uri"]
    Logger.info("[MCP] Resource updated: #{uri}")
    {:ok, state}
  end

  def handle_notification({:notification, "notifications/prompts/list_changed", _params}, state) do
    Logger.info("[MCP] Server prompts list changed")
    {:ok, state}
  end

  def handle_notification({:notification, method, _params}, state) do
    Logger.debug("[MCP] Notification: #{method}")
    {:ok, state}
  end

  def handle_notification({:request, method, _params}, state) do
    Logger.debug("[MCP] Server request: #{method}")
    {:ok, state}
  end
end

defmodule Charon.Client.PubSubNotificationHandler do
  @moduledoc """
  Notification handler that broadcasts events via Phoenix.PubSub or Registry.

  This handler allows multiple processes to subscribe to MCP notifications.

  ## Usage with Phoenix.PubSub

      {:ok, conn} = Charon.Client.Connection.start_link(
        transport: :stdio,
        command: "my-server",
        notification_handler: {
          Charon.Client.PubSubNotificationHandler,
          %{pubsub: MyApp.PubSub, topic: "mcp:events"}
        }
      )

      # Subscribe in another process
      Phoenix.PubSub.subscribe(MyApp.PubSub, "mcp:events")

      receive do
        {:mcp_notification, method, params} -> ...
      end

  ## Usage with Registry

      {:ok, conn} = Charon.Client.Connection.start_link(
        transport: :stdio,
        command: "my-server",
        notification_handler: {
          Charon.Client.PubSubNotificationHandler,
          %{registry: MyApp.MCPRegistry, key: "mcp_events"}
        }
      )
  """

  @behaviour Charon.Client.NotificationHandler

  @impl true
  def handle_notification(event, %{pubsub: pubsub, topic: topic} = state) do
    message = event_to_message(event)
    # Use apply to avoid compile-time warning when Phoenix.PubSub is not present
    apply(Phoenix.PubSub, :broadcast, [pubsub, topic, message])
    {:ok, state}
  end

  def handle_notification(event, %{registry: registry, key: key} = state) do
    message = event_to_message(event)
    Registry.dispatch(registry, key, fn entries ->
      for {pid, _value} <- entries do
        send(pid, message)
      end
    end)
    {:ok, state}
  end

  def handle_notification(_event, state) do
    {:ok, state}
  end

  defp event_to_message({:notification, method, params}) do
    {:mcp_notification, method, params}
  end

  defp event_to_message({:request, method, params}) do
    {:mcp_request, method, params}
  end
end
