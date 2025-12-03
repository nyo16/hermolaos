defmodule Hermolaos.Transport.MessageBuffer do
  @moduledoc """
  Buffer for handling newline-delimited JSON messages.

  MCP stdio transport uses newline-delimited JSON, where each JSON-RPC message
  is on its own line. This buffer handles:

  - Accumulating partial data chunks
  - Splitting on newlines to extract complete messages
  - Decoding JSON messages
  - Preserving incomplete data for the next chunk

  ## Design Notes

  This module is designed for high performance:
  - Uses binary operations for efficient string handling
  - Minimizes copying by using binary references where possible
  - Handles edge cases like empty lines and partial JSON

  ## Examples

      iex> buffer = Hermolaos.Transport.MessageBuffer.new()
      iex> {messages, buffer} = Hermolaos.Transport.MessageBuffer.append(buffer, ~s({"id":1}\\n))
      iex> messages
      [%{"id" => 1}]

      # Partial messages are buffered
      iex> buffer = Hermolaos.Transport.MessageBuffer.new()
      iex> {[], buffer} = Hermolaos.Transport.MessageBuffer.append(buffer, ~s({"id":))
      iex> {[%{"id" => 1}], _} = Hermolaos.Transport.MessageBuffer.append(buffer, ~s(1}\\n))
  """

  @type t :: %__MODULE__{
          buffer: binary(),
          stats: stats()
        }

  @type stats :: %{
          messages_received: non_neg_integer(),
          bytes_received: non_neg_integer(),
          parse_errors: non_neg_integer()
        }

  defstruct buffer: <<>>,
            stats: %{
              messages_received: 0,
              bytes_received: 0,
              parse_errors: 0
            }

  @doc """
  Creates a new empty message buffer.

  ## Examples

      iex> Hermolaos.Transport.MessageBuffer.new()
      %Hermolaos.Transport.MessageBuffer{buffer: "", stats: %{messages_received: 0, bytes_received: 0, parse_errors: 0}}
  """
  @spec new() :: t()
  def new do
    %__MODULE__{}
  end

  @doc """
  Appends data to the buffer and extracts any complete messages.

  Returns a tuple of `{messages, new_buffer}` where:
  - `messages` is a list of decoded JSON maps (may be empty)
  - `new_buffer` is the updated buffer with any incomplete data preserved

  ## Parameters

  - `buffer` - The current buffer state
  - `data` - Binary data to append

  ## Examples

      # Single complete message
      iex> buffer = Hermolaos.Transport.MessageBuffer.new()
      iex> {msgs, _} = Hermolaos.Transport.MessageBuffer.append(buffer, ~s({"jsonrpc":"2.0"}\\n))
      iex> msgs
      [%{"jsonrpc" => "2.0"}]

      # Multiple messages in one chunk
      iex> buffer = Hermolaos.Transport.MessageBuffer.new()
      iex> {msgs, _} = Hermolaos.Transport.MessageBuffer.append(buffer, ~s({"id":1}\\n{"id":2}\\n))
      iex> length(msgs)
      2

      # Partial message preserved
      iex> buffer = Hermolaos.Transport.MessageBuffer.new()
      iex> {[], buffer} = Hermolaos.Transport.MessageBuffer.append(buffer, ~s({"partial":))
      iex> buffer.buffer
      ~s({"partial":)
  """
  @spec append(t(), binary()) :: {[map()], t()}
  def append(%__MODULE__{buffer: existing, stats: stats} = state, data) when is_binary(data) do
    combined = existing <> data
    new_stats = %{stats | bytes_received: stats.bytes_received + byte_size(data)}

    case extract_messages(combined) do
      {lines, remainder} ->
        {messages, parse_errors} = parse_lines(lines)

        updated_stats = %{
          new_stats
          | messages_received: new_stats.messages_received + length(messages),
            parse_errors: new_stats.parse_errors + parse_errors
        }

        {messages, %{state | buffer: remainder, stats: updated_stats}}
    end
  end

  @doc """
  Resets the buffer, discarding any buffered data.

  Returns any messages that could be extracted from the remaining buffer
  before clearing it.

  ## Examples

      iex> buffer = %Hermolaos.Transport.MessageBuffer{buffer: "partial data"}
      iex> {[], new_buffer} = Hermolaos.Transport.MessageBuffer.reset(buffer)
      iex> new_buffer.buffer
      ""
  """
  @spec reset(t()) :: {[map()], t()}
  def reset(%__MODULE__{buffer: remaining} = state) do
    # Try to parse any remaining data as a message (in case final newline was missing)
    messages =
      case parse_line(remaining) do
        {:ok, msg} -> [msg]
        :skip -> []
        :error -> []
      end

    {messages, %{state | buffer: <<>>}}
  end

  @doc """
  Returns the current buffer size in bytes.

  ## Examples

      iex> buffer = %Hermolaos.Transport.MessageBuffer{buffer: "12345"}
      iex> Hermolaos.Transport.MessageBuffer.buffer_size(buffer)
      5
  """
  @spec buffer_size(t()) :: non_neg_integer()
  def buffer_size(%__MODULE__{buffer: buffer}) do
    byte_size(buffer)
  end

  @doc """
  Returns buffer statistics.

  ## Examples

      iex> buffer = Hermolaos.Transport.MessageBuffer.new()
      iex> Hermolaos.Transport.MessageBuffer.stats(buffer)
      %{messages_received: 0, bytes_received: 0, parse_errors: 0}
  """
  @spec stats(t()) :: stats()
  def stats(%__MODULE__{stats: stats}), do: stats

  @doc """
  Checks if the buffer has pending (incomplete) data.

  ## Examples

      iex> buffer = Hermolaos.Transport.MessageBuffer.new()
      iex> Hermolaos.Transport.MessageBuffer.has_pending?(buffer)
      false

      iex> buffer = %Hermolaos.Transport.MessageBuffer{buffer: "pending"}
      iex> Hermolaos.Transport.MessageBuffer.has_pending?(buffer)
      true
  """
  @spec has_pending?(t()) :: boolean()
  def has_pending?(%__MODULE__{buffer: <<>>}), do: false
  def has_pending?(%__MODULE__{}), do: true

  # ============================================================================
  # Private Functions
  # ============================================================================

  # Splits the buffer on newlines, returning complete lines and the remainder
  @spec extract_messages(binary()) :: {[binary()], binary()}
  defp extract_messages(data) do
    case :binary.split(data, "\n", [:global]) do
      # No newlines found - everything is remainder
      [remainder] ->
        {[], remainder}

      # Split found - last element is remainder (could be empty)
      parts ->
        {complete, [remainder]} = Enum.split(parts, -1)
        {complete, remainder}
    end
  end

  # Parse a list of lines into messages, counting parse errors
  @spec parse_lines([binary()]) :: {[map()], non_neg_integer()}
  defp parse_lines(lines) do
    Enum.reduce(lines, {[], 0}, fn line, {messages, errors} ->
      case parse_line(line) do
        {:ok, msg} -> {[msg | messages], errors}
        :skip -> {messages, errors}
        :error -> {messages, errors + 1}
      end
    end)
    |> then(fn {messages, errors} -> {Enum.reverse(messages), errors} end)
  end

  # Parse a single line into a JSON message
  @spec parse_line(binary()) :: {:ok, map()} | :skip | :error
  defp parse_line(<<>>), do: :skip
  defp parse_line(line) when is_binary(line) do
    trimmed = String.trim(line)

    if trimmed == "" do
      :skip
    else
      case Jason.decode(trimmed) do
        {:ok, map} when is_map(map) -> {:ok, map}
        {:ok, _} -> :error  # Valid JSON but not an object
        {:error, _} -> :error
      end
    end
  end
end
