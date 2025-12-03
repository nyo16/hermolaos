defmodule Charon.Protocol.ErrorsTest do
  use ExUnit.Case, async: true

  alias Charon.Protocol.Errors

  describe "error code constants" do
    test "returns correct error codes" do
      assert Errors.parse_error_code() == -32700
      assert Errors.invalid_request_code() == -32600
      assert Errors.method_not_found_code() == -32601
      assert Errors.invalid_params_code() == -32602
      assert Errors.internal_error_code() == -32603
      assert Errors.connection_closed_code() == -32000
      assert Errors.request_timeout_code() == -32001
      assert Errors.request_cancelled_code() == -32002
      assert Errors.resource_not_found_code() == -32003
    end
  end

  describe "error constructors" do
    test "parse_error/0 creates parse error" do
      error = Errors.parse_error()
      assert error.code == -32700
      assert error.message == "Parse error"
      assert error.data == nil
    end

    test "parse_error/1 creates parse error with data" do
      error = Errors.parse_error("unexpected token")
      assert error.code == -32700
      assert error.data == "unexpected token"
    end

    test "invalid_request/0 creates invalid request error" do
      error = Errors.invalid_request()
      assert error.code == -32600
      assert error.message == "Invalid Request"
    end

    test "invalid_request/1 creates invalid request error with data" do
      error = Errors.invalid_request("missing method")
      assert error.data == "missing method"
    end

    test "method_not_found/1 creates method not found error" do
      error = Errors.method_not_found("unknown/method")
      assert error.code == -32601
      assert error.message == "Method not found: unknown/method"
    end

    test "invalid_params/0 creates invalid params error" do
      error = Errors.invalid_params()
      assert error.code == -32602
      assert error.message == "Invalid params"
    end

    test "invalid_params/1 creates invalid params error with details" do
      error = Errors.invalid_params(%{field: "missing"})
      assert error.data == %{field: "missing"}
    end

    test "internal_error/0 creates internal error" do
      error = Errors.internal_error()
      assert error.code == -32603
      assert error.message == "Internal error"
    end

    test "internal_error/1 creates internal error with details" do
      error = Errors.internal_error("database error")
      assert error.data == "database error"
    end

    test "connection_closed/0 creates connection closed error" do
      error = Errors.connection_closed()
      assert error.code == -32000
      assert error.message == "Connection closed"
    end

    test "connection_closed/1 creates connection closed error with reason" do
      error = Errors.connection_closed(:normal)
      assert error.data == :normal
    end

    test "request_timeout/1 creates request timeout error" do
      error = Errors.request_timeout("tools/call")
      assert error.code == -32001
      assert error.message == "Request timeout: tools/call"
    end

    test "request_timeout/2 creates request timeout error with timeout" do
      error = Errors.request_timeout("tools/call", 30000)
      assert error.data == %{timeout_ms: 30000}
    end

    test "request_cancelled/0 creates request cancelled error" do
      error = Errors.request_cancelled()
      assert error.code == -32002
      assert error.message == "Request cancelled"
    end

    test "request_cancelled/1 creates request cancelled error with reason" do
      error = Errors.request_cancelled("user cancelled")
      assert error.data == "user cancelled"
    end

    test "resource_not_found/1 creates resource not found error" do
      error = Errors.resource_not_found("file:///missing")
      assert error.code == -32003
      assert error.message == "Resource not found: file:///missing"
    end
  end

  describe "from_response/1" do
    test "converts JSON-RPC error response to Errors struct" do
      response = %{"error" => %{"code" => -32601, "message" => "Method not found"}}

      assert {:ok, error} = Errors.from_response(response)
      assert error.code == -32601
      assert error.message == "Method not found"
      assert error.data == nil
    end

    test "includes data when present" do
      response = %{
        "error" => %{
          "code" => -32602,
          "message" => "Invalid params",
          "data" => %{"field" => "name"}
        }
      }

      assert {:ok, error} = Errors.from_response(response)
      assert error.data == %{"field" => "name"}
    end

    test "returns error for non-error response" do
      response = %{"result" => %{}}
      assert {:error, :not_an_error} = Errors.from_response(response)
    end

    test "returns error for invalid error format" do
      response = %{"error" => "invalid"}
      assert {:error, :not_an_error} = Errors.from_response(response)
    end

    test "returns error for missing required fields" do
      response = %{"error" => %{"code" => -32600}}
      assert {:error, :invalid_error} = Errors.from_response(response)
    end
  end

  describe "to_map/1" do
    test "converts error to JSON-RPC error map" do
      error = %Errors{code: -32600, message: "Invalid Request", data: nil}

      map = Errors.to_map(error)

      assert map == %{"code" => -32600, "message" => "Invalid Request"}
    end

    test "includes data when present" do
      error = %Errors{code: -32602, message: "Invalid params", data: %{field: "x"}}

      map = Errors.to_map(error)

      assert map["data"] == %{field: "x"}
    end
  end

  describe "to_exception/1" do
    test "converts error to Charon.Error exception" do
      error = Errors.method_not_found("test/method")

      exception = Errors.to_exception(error)

      assert %Charon.Error{} = exception
      assert exception.code == -32601
      assert exception.message =~ "Method not found"
    end
  end

  describe "code_to_name/1" do
    test "converts standard JSON-RPC codes" do
      assert Errors.code_to_name(-32700) == :parse_error
      assert Errors.code_to_name(-32600) == :invalid_request
      assert Errors.code_to_name(-32601) == :method_not_found
      assert Errors.code_to_name(-32602) == :invalid_params
      assert Errors.code_to_name(-32603) == :internal_error
    end

    test "converts MCP-specific codes" do
      assert Errors.code_to_name(-32000) == :connection_closed
      assert Errors.code_to_name(-32001) == :request_timeout
      assert Errors.code_to_name(-32002) == :request_cancelled
      assert Errors.code_to_name(-32003) == :resource_not_found
    end

    test "returns :unknown for unrecognized codes" do
      assert Errors.code_to_name(-99999) == :unknown
      assert Errors.code_to_name(0) == :unknown
    end
  end

  describe "standard_error?/1" do
    test "returns true for standard JSON-RPC errors" do
      assert Errors.standard_error?(-32700)
      assert Errors.standard_error?(-32600)
      assert Errors.standard_error?(-32601)
      assert Errors.standard_error?(-32602)
      assert Errors.standard_error?(-32603)
    end

    test "returns false for MCP-specific errors" do
      refute Errors.standard_error?(-32000)
      refute Errors.standard_error?(-32001)
      refute Errors.standard_error?(-32002)
      refute Errors.standard_error?(-32003)
    end
  end

  describe "retriable?/1" do
    test "returns true for connection and timeout errors" do
      assert Errors.retriable?(-32000)
      assert Errors.retriable?(-32001)
    end

    test "returns false for other errors" do
      refute Errors.retriable?(-32700)
      refute Errors.retriable?(-32601)
      refute Errors.retriable?(-32002)
    end

    test "accepts error struct" do
      error = Errors.request_timeout("test")
      assert Errors.retriable?(error)

      error = Errors.method_not_found("test")
      refute Errors.retriable?(error)
    end
  end
end
