defmodule Charon.Error do
  @moduledoc """
  Exception struct for MCP/JSON-RPC errors.

  This exception can be raised when an MCP operation fails with an error
  response from the server or a client-side error occurs.

  ## Examples

      try do
        result = Charon.call_tool(client, "unknown_tool", %{})
      rescue
        e in Charon.Error ->
          IO.puts("Tool call failed: \#{e.message}")
          IO.puts("Error code: \#{e.code}")
      end
  """

  @type t :: %__MODULE__{
          code: integer(),
          message: String.t(),
          data: term()
        }

  defexception [:code, :message, :data]

  @impl true
  def message(%__MODULE__{code: code, message: msg, data: nil}) do
    "MCP Error #{code}: #{msg}"
  end

  def message(%__MODULE__{code: code, message: msg, data: data}) do
    "MCP Error #{code}: #{msg} (#{inspect(data)})"
  end

  @doc """
  Creates a new Charon.Error from components.

  ## Examples

      iex> Charon.Error.new(-32601, "Method not found")
      %Charon.Error{code: -32601, message: "Method not found", data: nil}
  """
  @spec new(integer(), String.t(), term()) :: t()
  def new(code, message, data \\ nil) do
    %__MODULE__{code: code, message: message, data: data}
  end
end
