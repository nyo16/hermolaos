defmodule Charon.Protocol.JsonRpc do
  @moduledoc """
  JSON-RPC 2.0 encoding and decoding for MCP protocol messages.

  This module handles the low-level JSON-RPC 2.0 message format used by MCP.
  All MCP communication uses JSON-RPC 2.0 as the underlying protocol.

  ## Message Types

  - **Request**: Has `id`, `method`, and optional `params`
  - **Response**: Has `id` and either `result` or `error`
  - **Notification**: Has `method` and optional `params`, but no `id`

  ## Examples

      # Encoding a request
      iex> Charon.Protocol.JsonRpc.encode_request(1, "tools/list", %{})
      ~s({"id":1,"jsonrpc":"2.0","method":"tools/list","params":{}})

      # Decoding a response
      iex> Charon.Protocol.JsonRpc.decode(~s({"jsonrpc":"2.0","id":1,"result":{"tools":[]}}))
      {:ok, {:response, %{"jsonrpc" => "2.0", "id" => 1, "result" => %{"tools" => []}}}}
  """

  @json_rpc_version "2.0"

  @type id :: integer() | String.t()
  @type params :: map() | list()

  @type request :: %{
          required(:jsonrpc) => String.t(),
          required(:id) => id(),
          required(:method) => String.t(),
          optional(:params) => params()
        }

  @type notification :: %{
          required(:jsonrpc) => String.t(),
          required(:method) => String.t(),
          optional(:params) => params()
        }

  @type response :: %{
          required(:jsonrpc) => String.t(),
          required(:id) => id(),
          required(:result) => term()
        }

  @type error_response :: %{
          required(:jsonrpc) => String.t(),
          required(:id) => id() | nil,
          required(:error) => error_object()
        }

  @type error_object :: %{
          required(:code) => integer(),
          required(:message) => String.t(),
          optional(:data) => term()
        }

  @type message_type :: :request | :notification | :response | :error_response
  @type decoded_message :: {message_type(), map()}

  # ============================================================================
  # Encoding
  # ============================================================================

  @doc """
  Encodes a JSON-RPC 2.0 request message.

  ## Parameters

  - `id` - Unique request identifier (integer or string)
  - `method` - The RPC method name
  - `params` - Optional parameters (map or list)

  ## Examples

      iex> Charon.Protocol.JsonRpc.encode_request(1, "tools/list", %{})
      ~s({"id":1,"jsonrpc":"2.0","method":"tools/list","params":{}})

      iex> Charon.Protocol.JsonRpc.encode_request("abc", "ping", nil)
      ~s({"id":"abc","jsonrpc":"2.0","method":"ping"})
  """
  @spec encode_request(id(), String.t(), params() | nil) :: String.t()
  def encode_request(id, method, params \\ nil) do
    %{"jsonrpc" => @json_rpc_version, "id" => id, "method" => method}
    |> maybe_add_params(params)
    |> Jason.encode!()
  end

  @doc """
  Encodes a JSON-RPC 2.0 notification message (no response expected).

  Notifications are like requests but without an `id` field, meaning
  the server should not send a response.

  ## Parameters

  - `method` - The RPC method name
  - `params` - Optional parameters (map or list)

  ## Examples

      iex> Charon.Protocol.JsonRpc.encode_notification("notifications/initialized", %{})
      ~s({"jsonrpc":"2.0","method":"notifications/initialized","params":{}})
  """
  @spec encode_notification(String.t(), params() | nil) :: String.t()
  def encode_notification(method, params \\ nil) do
    %{"jsonrpc" => @json_rpc_version, "method" => method}
    |> maybe_add_params(params)
    |> Jason.encode!()
  end

  @doc """
  Encodes a JSON-RPC 2.0 success response.

  ## Parameters

  - `id` - The request ID being responded to
  - `result` - The result data

  ## Examples

      iex> Charon.Protocol.JsonRpc.encode_response(1, %{tools: []})
      ~s({"id":1,"jsonrpc":"2.0","result":{"tools":[]}})
  """
  @spec encode_response(id(), term()) :: String.t()
  def encode_response(id, result) do
    %{"jsonrpc" => @json_rpc_version, "id" => id, "result" => result}
    |> Jason.encode!()
  end

  @doc """
  Encodes a JSON-RPC 2.0 error response.

  ## Parameters

  - `id` - The request ID (can be nil if request couldn't be parsed)
  - `code` - Error code (integer)
  - `message` - Human-readable error message
  - `data` - Optional additional error data

  ## Examples

      iex> Charon.Protocol.JsonRpc.encode_error_response(1, -32600, "Invalid Request")
      ~s({"error":{"code":-32600,"message":"Invalid Request"},"id":1,"jsonrpc":"2.0"})
  """
  @spec encode_error_response(id() | nil, integer(), String.t(), term()) :: String.t()
  def encode_error_response(id, code, message, data \\ nil) do
    error =
      %{"code" => code, "message" => message}
      |> maybe_add_data(data)

    %{"jsonrpc" => @json_rpc_version, "id" => id, "error" => error}
    |> Jason.encode!()
  end

  # ============================================================================
  # Decoding
  # ============================================================================

  @doc """
  Decodes a JSON-RPC 2.0 message and classifies its type.

  Returns `{:ok, {type, message}}` where type is one of:
  - `:request` - A request expecting a response
  - `:notification` - A notification (no response expected)
  - `:response` - A successful response
  - `:error_response` - An error response

  ## Examples

      iex> Charon.Protocol.JsonRpc.decode(~s({"jsonrpc":"2.0","id":1,"method":"ping"}))
      {:ok, {:request, %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}}}

      iex> Charon.Protocol.JsonRpc.decode(~s({"jsonrpc":"2.0","method":"notifications/initialized"}))
      {:ok, {:notification, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}}}

      iex> Charon.Protocol.JsonRpc.decode("invalid json")
      {:error, :parse_error}
  """
  @spec decode(String.t()) :: {:ok, decoded_message()} | {:error, :parse_error | :invalid_message}
  def decode(json_string) when is_binary(json_string) do
    case Jason.decode(json_string) do
      {:ok, decoded} when is_map(decoded) ->
        classify_message(decoded)

      {:ok, _} ->
        {:error, :invalid_message}

      {:error, _} ->
        {:error, :parse_error}
    end
  end

  @doc """
  Decodes a JSON-RPC 2.0 message, raising on error.

  ## Examples

      iex> Charon.Protocol.JsonRpc.decode!(~s({"jsonrpc":"2.0","id":1,"result":{}}))
      {:response, %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}}
  """
  @spec decode!(String.t()) :: decoded_message()
  def decode!(json_string) do
    case decode(json_string) do
      {:ok, result} -> result
      {:error, reason} -> raise ArgumentError, "Failed to decode JSON-RPC message: #{reason}"
    end
  end

  # ============================================================================
  # Message Classification
  # ============================================================================

  @doc """
  Classifies a decoded JSON-RPC message by its type.

  ## Examples

      iex> Charon.Protocol.JsonRpc.classify_message(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})
      {:ok, {:request, %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}}}
  """
  @spec classify_message(map()) :: {:ok, decoded_message()} | {:error, :invalid_message}
  def classify_message(message) when is_map(message) do
    cond do
      # Error response: has id and error
      has_key?(message, "error") and has_key?(message, "id") ->
        {:ok, {:error_response, message}}

      # Success response: has id and result
      has_key?(message, "result") and has_key?(message, "id") ->
        {:ok, {:response, message}}

      # Request: has id and method
      has_key?(message, "method") and has_key?(message, "id") ->
        {:ok, {:request, message}}

      # Notification: has method but no id
      has_key?(message, "method") and not has_key?(message, "id") ->
        {:ok, {:notification, message}}

      true ->
        {:error, :invalid_message}
    end
  end

  @doc """
  Returns the message type of a decoded message.

  ## Examples

      iex> Charon.Protocol.JsonRpc.message_type(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})
      :request
  """
  @spec message_type(map()) :: message_type() | :unknown
  def message_type(message) when is_map(message) do
    case classify_message(message) do
      {:ok, {type, _}} -> type
      {:error, _} -> :unknown
    end
  end

  # ============================================================================
  # Validation
  # ============================================================================

  @doc """
  Validates that a message is a proper JSON-RPC 2.0 request.

  ## Examples

      iex> Charon.Protocol.JsonRpc.valid_request?(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})
      true

      iex> Charon.Protocol.JsonRpc.valid_request?(%{"id" => 1, "method" => "ping"})
      false
  """
  @spec valid_request?(map()) :: boolean()
  def valid_request?(message) when is_map(message) do
    has_key?(message, "jsonrpc") and
      message["jsonrpc"] == @json_rpc_version and
      has_key?(message, "id") and
      has_key?(message, "method") and
      is_binary(message["method"])
  end

  def valid_request?(_), do: false

  @doc """
  Validates that a message is a proper JSON-RPC 2.0 notification.
  """
  @spec valid_notification?(map()) :: boolean()
  def valid_notification?(message) when is_map(message) do
    has_key?(message, "jsonrpc") and
      message["jsonrpc"] == @json_rpc_version and
      not has_key?(message, "id") and
      has_key?(message, "method") and
      is_binary(message["method"])
  end

  def valid_notification?(_), do: false

  @doc """
  Validates that a message is a proper JSON-RPC 2.0 response (success or error).
  """
  @spec valid_response?(map()) :: boolean()
  def valid_response?(message) when is_map(message) do
    has_key?(message, "jsonrpc") and
      message["jsonrpc"] == @json_rpc_version and
      has_key?(message, "id") and
      (has_key?(message, "result") or has_key?(message, "error"))
  end

  def valid_response?(_), do: false

  # ============================================================================
  # Utilities
  # ============================================================================

  @doc """
  Extracts the request/response ID from a message.

  ## Examples

      iex> Charon.Protocol.JsonRpc.get_id(%{"id" => 42})
      42

      iex> Charon.Protocol.JsonRpc.get_id(%{"method" => "notify"})
      nil
  """
  @spec get_id(map()) :: id() | nil
  def get_id(message) when is_map(message), do: message["id"]

  @doc """
  Extracts the method name from a request or notification.
  """
  @spec get_method(map()) :: String.t() | nil
  def get_method(message) when is_map(message), do: message["method"]

  @doc """
  Extracts parameters from a request or notification.
  """
  @spec get_params(map()) :: params() | nil
  def get_params(message) when is_map(message), do: message["params"]

  @doc """
  Extracts the result from a successful response.
  """
  @spec get_result(map()) :: term() | nil
  def get_result(message) when is_map(message), do: message["result"]

  @doc """
  Extracts the error object from an error response.
  """
  @spec get_error(map()) :: error_object() | nil
  def get_error(message) when is_map(message), do: message["error"]

  @doc """
  Checks if a response is an error response.
  """
  @spec error_response?(map()) :: boolean()
  def error_response?(message) when is_map(message), do: has_key?(message, "error")

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp has_key?(map, key), do: Map.has_key?(map, key)

  defp maybe_add_params(map, nil), do: map
  defp maybe_add_params(map, params), do: Map.put(map, "params", params)

  defp maybe_add_data(map, nil), do: map
  defp maybe_add_data(map, data), do: Map.put(map, "data", data)
end
