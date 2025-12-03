defmodule Charon.Protocol.Errors do
  @moduledoc """
  JSON-RPC 2.0 and MCP error codes and error handling utilities.

  ## Standard JSON-RPC 2.0 Error Codes

  | Code   | Message          | Description                           |
  |--------|------------------|---------------------------------------|
  | -32700 | Parse error      | Invalid JSON                          |
  | -32600 | Invalid Request  | Not a valid JSON-RPC request          |
  | -32601 | Method not found | Method doesn't exist                  |
  | -32602 | Invalid params   | Invalid method parameters             |
  | -32603 | Internal error   | Internal JSON-RPC error               |

  ## MCP-Specific Error Codes (reserved: -32000 to -32099)

  | Code   | Description                                       |
  |--------|---------------------------------------------------|
  | -32000 | Connection closed unexpectedly                    |
  | -32001 | Request timed out                                 |
  | -32002 | Request was cancelled                             |
  | -32003 | Resource not found                                |

  ## Examples

      # Create an error struct
      error = Charon.Protocol.Errors.method_not_found("unknown/method")

      # Convert to exception for raising
      raise Charon.Protocol.Errors.to_exception(error)

      # Parse error from JSON-RPC response
      {:ok, error} = Charon.Protocol.Errors.from_response(response)
  """

  # ============================================================================
  # Standard JSON-RPC 2.0 Error Codes
  # ============================================================================

  @parse_error -32700
  @invalid_request -32600
  @method_not_found -32601
  @invalid_params -32602
  @internal_error -32603

  # Server error codes: -32000 to -32099 (reserved for implementation)
  @connection_closed -32000
  @request_timeout -32001
  @request_cancelled -32002
  @resource_not_found -32003

  # ============================================================================
  # Type Definitions
  # ============================================================================

  @type t :: %__MODULE__{
          code: integer(),
          message: String.t(),
          data: term()
        }

  @type error_code ::
          :parse_error
          | :invalid_request
          | :method_not_found
          | :invalid_params
          | :internal_error
          | :connection_closed
          | :request_timeout
          | :request_cancelled
          | :resource_not_found

  defstruct [:code, :message, :data]

  # ============================================================================
  # Error Code Constants (for external use)
  # ============================================================================

  @doc "Returns the JSON-RPC parse error code (-32700)"
  @spec parse_error_code() :: integer()
  def parse_error_code, do: @parse_error

  @doc "Returns the JSON-RPC invalid request error code (-32600)"
  @spec invalid_request_code() :: integer()
  def invalid_request_code, do: @invalid_request

  @doc "Returns the JSON-RPC method not found error code (-32601)"
  @spec method_not_found_code() :: integer()
  def method_not_found_code, do: @method_not_found

  @doc "Returns the JSON-RPC invalid params error code (-32602)"
  @spec invalid_params_code() :: integer()
  def invalid_params_code, do: @invalid_params

  @doc "Returns the JSON-RPC internal error code (-32603)"
  @spec internal_error_code() :: integer()
  def internal_error_code, do: @internal_error

  @doc "Returns the MCP connection closed error code (-32000)"
  @spec connection_closed_code() :: integer()
  def connection_closed_code, do: @connection_closed

  @doc "Returns the MCP request timeout error code (-32001)"
  @spec request_timeout_code() :: integer()
  def request_timeout_code, do: @request_timeout

  @doc "Returns the MCP request cancelled error code (-32002)"
  @spec request_cancelled_code() :: integer()
  def request_cancelled_code, do: @request_cancelled

  @doc "Returns the MCP resource not found error code (-32003)"
  @spec resource_not_found_code() :: integer()
  def resource_not_found_code, do: @resource_not_found

  # ============================================================================
  # Error Constructors
  # ============================================================================

  @doc """
  Creates a parse error (invalid JSON).

  ## Examples

      iex> Charon.Protocol.Errors.parse_error()
      %Charon.Protocol.Errors{code: -32700, message: "Parse error", data: nil}
  """
  @spec parse_error(term()) :: t()
  def parse_error(data \\ nil) do
    %__MODULE__{code: @parse_error, message: "Parse error", data: data}
  end

  @doc """
  Creates an invalid request error.

  ## Examples

      iex> Charon.Protocol.Errors.invalid_request("Missing method field")
      %Charon.Protocol.Errors{code: -32600, message: "Invalid Request", data: "Missing method field"}
  """
  @spec invalid_request(term()) :: t()
  def invalid_request(data \\ nil) do
    %__MODULE__{code: @invalid_request, message: "Invalid Request", data: data}
  end

  @doc """
  Creates a method not found error.

  ## Examples

      iex> Charon.Protocol.Errors.method_not_found("unknown/method")
      %Charon.Protocol.Errors{code: -32601, message: "Method not found: unknown/method", data: nil}
  """
  @spec method_not_found(String.t()) :: t()
  def method_not_found(method) do
    %__MODULE__{code: @method_not_found, message: "Method not found: #{method}", data: nil}
  end

  @doc """
  Creates an invalid params error.

  ## Examples

      iex> Charon.Protocol.Errors.invalid_params(%{field: "name", reason: "required"})
      %Charon.Protocol.Errors{code: -32602, message: "Invalid params", data: %{field: "name", reason: "required"}}
  """
  @spec invalid_params(term()) :: t()
  def invalid_params(details \\ nil) do
    %__MODULE__{code: @invalid_params, message: "Invalid params", data: details}
  end

  @doc """
  Creates an internal error.

  ## Examples

      iex> Charon.Protocol.Errors.internal_error("Database connection failed")
      %Charon.Protocol.Errors{code: -32603, message: "Internal error", data: "Database connection failed"}
  """
  @spec internal_error(term()) :: t()
  def internal_error(details \\ nil) do
    %__MODULE__{code: @internal_error, message: "Internal error", data: details}
  end

  @doc """
  Creates a connection closed error.

  ## Examples

      iex> Charon.Protocol.Errors.connection_closed()
      %Charon.Protocol.Errors{code: -32000, message: "Connection closed", data: nil}
  """
  @spec connection_closed(term()) :: t()
  def connection_closed(reason \\ nil) do
    %__MODULE__{code: @connection_closed, message: "Connection closed", data: reason}
  end

  @doc """
  Creates a request timeout error.

  ## Examples

      iex> Charon.Protocol.Errors.request_timeout("tools/call", 30000)
      %Charon.Protocol.Errors{code: -32001, message: "Request timeout: tools/call", data: %{timeout_ms: 30000}}
  """
  @spec request_timeout(String.t(), integer() | nil) :: t()
  def request_timeout(method, timeout_ms \\ nil) do
    data = if timeout_ms, do: %{timeout_ms: timeout_ms}, else: nil
    %__MODULE__{code: @request_timeout, message: "Request timeout: #{method}", data: data}
  end

  @doc """
  Creates a request cancelled error.

  ## Examples

      iex> Charon.Protocol.Errors.request_cancelled("User cancelled")
      %Charon.Protocol.Errors{code: -32002, message: "Request cancelled", data: "User cancelled"}
  """
  @spec request_cancelled(term()) :: t()
  def request_cancelled(reason \\ nil) do
    %__MODULE__{code: @request_cancelled, message: "Request cancelled", data: reason}
  end

  @doc """
  Creates a resource not found error.

  ## Examples

      iex> Charon.Protocol.Errors.resource_not_found("file:///missing.txt")
      %Charon.Protocol.Errors{code: -32003, message: "Resource not found: file:///missing.txt", data: nil}
  """
  @spec resource_not_found(String.t()) :: t()
  def resource_not_found(uri) do
    %__MODULE__{code: @resource_not_found, message: "Resource not found: #{uri}", data: nil}
  end

  # ============================================================================
  # Conversion Functions
  # ============================================================================

  @doc """
  Parses an error from a JSON-RPC error response.

  ## Examples

      iex> response = %{"error" => %{"code" => -32601, "message" => "Method not found"}}
      iex> Charon.Protocol.Errors.from_response(response)
      {:ok, %Charon.Protocol.Errors{code: -32601, message: "Method not found", data: nil}}

      iex> Charon.Protocol.Errors.from_response(%{"result" => %{}})
      {:error, :not_an_error}
  """
  @spec from_response(map()) :: {:ok, t()} | {:error, :not_an_error | :invalid_error}
  def from_response(%{"error" => error}) when is_map(error) do
    case error do
      %{"code" => code, "message" => message} when is_integer(code) and is_binary(message) ->
        {:ok, %__MODULE__{code: code, message: message, data: error["data"]}}

      _ ->
        {:error, :invalid_error}
    end
  end

  def from_response(_), do: {:error, :not_an_error}

  @doc """
  Converts an error struct to a map suitable for JSON-RPC response.

  ## Examples

      iex> error = %Charon.Protocol.Errors{code: -32600, message: "Invalid", data: nil}
      iex> Charon.Protocol.Errors.to_map(error)
      %{"code" => -32600, "message" => "Invalid"}
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{code: code, message: message, data: nil}) do
    %{"code" => code, "message" => message}
  end

  def to_map(%__MODULE__{code: code, message: message, data: data}) do
    %{"code" => code, "message" => message, "data" => data}
  end

  @doc """
  Converts an error struct to a Charon.Error exception.

  ## Examples

      iex> error = Charon.Protocol.Errors.method_not_found("ping")
      iex> exception = Charon.Protocol.Errors.to_exception(error)
      iex> exception.message
      "MCP Error -32601: Method not found: ping"
  """
  @spec to_exception(t()) :: Charon.Error.t()
  def to_exception(%__MODULE__{} = error) do
    %Charon.Error{code: error.code, message: error.message, data: error.data}
  end

  # ============================================================================
  # Error Code Classification
  # ============================================================================

  @doc """
  Converts an error code to its symbolic name.

  ## Examples

      iex> Charon.Protocol.Errors.code_to_name(-32700)
      :parse_error

      iex> Charon.Protocol.Errors.code_to_name(-99999)
      :unknown
  """
  @spec code_to_name(integer()) :: error_code() | :unknown
  def code_to_name(@parse_error), do: :parse_error
  def code_to_name(@invalid_request), do: :invalid_request
  def code_to_name(@method_not_found), do: :method_not_found
  def code_to_name(@invalid_params), do: :invalid_params
  def code_to_name(@internal_error), do: :internal_error
  def code_to_name(@connection_closed), do: :connection_closed
  def code_to_name(@request_timeout), do: :request_timeout
  def code_to_name(@request_cancelled), do: :request_cancelled
  def code_to_name(@resource_not_found), do: :resource_not_found
  def code_to_name(_), do: :unknown

  @doc """
  Checks if an error is a standard JSON-RPC error (vs MCP-specific).

  ## Examples

      iex> Charon.Protocol.Errors.standard_error?(-32700)
      true

      iex> Charon.Protocol.Errors.standard_error?(-32000)
      false
  """
  @spec standard_error?(integer()) :: boolean()
  def standard_error?(code) when code in [@parse_error, @invalid_request, @method_not_found, @invalid_params, @internal_error] do
    true
  end

  def standard_error?(_), do: false

  @doc """
  Checks if an error is retriable (connection issues, timeouts).

  ## Examples

      iex> Charon.Protocol.Errors.retriable?(-32000)
      true

      iex> Charon.Protocol.Errors.retriable?(-32601)
      false
  """
  @spec retriable?(integer() | t()) :: boolean()
  def retriable?(%__MODULE__{code: code}), do: retriable?(code)
  def retriable?(@connection_closed), do: true
  def retriable?(@request_timeout), do: true
  def retriable?(_), do: false
end
