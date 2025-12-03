defmodule Charon.Transport.MessageBufferTest do
  use ExUnit.Case, async: true

  alias Charon.Transport.MessageBuffer

  describe "new/0" do
    test "creates empty buffer" do
      buffer = MessageBuffer.new()
      assert buffer.buffer == ""
      assert buffer.stats.messages_received == 0
      assert buffer.stats.bytes_received == 0
      assert buffer.stats.parse_errors == 0
    end
  end

  describe "append/2" do
    test "handles single complete message" do
      buffer = MessageBuffer.new()
      {messages, _buffer} = MessageBuffer.append(buffer, ~s({"id":1}\n))

      assert [%{"id" => 1}] = messages
    end

    test "handles multiple complete messages" do
      buffer = MessageBuffer.new()
      {messages, _buffer} = MessageBuffer.append(buffer, ~s({"id":1}\n{"id":2}\n))

      assert [%{"id" => 1}, %{"id" => 2}] = messages
    end

    test "buffers partial message" do
      buffer = MessageBuffer.new()
      {messages, buffer} = MessageBuffer.append(buffer, ~s({"id":))

      assert messages == []
      assert buffer.buffer == ~s({"id":)
    end

    test "completes buffered message" do
      buffer = MessageBuffer.new()
      {[], buffer} = MessageBuffer.append(buffer, ~s({"id":))
      {messages, buffer} = MessageBuffer.append(buffer, ~s(1}\n))

      assert [%{"id" => 1}] = messages
      assert buffer.buffer == ""
    end

    test "handles message spanning multiple chunks" do
      buffer = MessageBuffer.new()
      {[], buffer} = MessageBuffer.append(buffer, ~s({"na))
      {[], buffer} = MessageBuffer.append(buffer, ~s(me":"))
      {[], buffer} = MessageBuffer.append(buffer, ~s(test"))
      {messages, _buffer} = MessageBuffer.append(buffer, ~s(}\n))

      assert [%{"name" => "test"}] = messages
    end

    test "skips empty lines" do
      buffer = MessageBuffer.new()
      {messages, _buffer} = MessageBuffer.append(buffer, ~s(\n\n{"id":1}\n\n))

      assert [%{"id" => 1}] = messages
    end

    test "handles messages with trailing incomplete" do
      buffer = MessageBuffer.new()
      {messages, buffer} = MessageBuffer.append(buffer, ~s({"id":1}\n{"id":2}\n{"partial":))

      assert [%{"id" => 1}, %{"id" => 2}] = messages
      assert buffer.buffer == ~s({"partial":)
    end

    test "updates stats" do
      buffer = MessageBuffer.new()
      {_, buffer} = MessageBuffer.append(buffer, ~s({"id":1}\n))

      assert buffer.stats.messages_received == 1
      # {"id":1}\n is 9 bytes
      assert buffer.stats.bytes_received == 9
    end

    test "counts parse errors" do
      buffer = MessageBuffer.new()
      {messages, buffer} = MessageBuffer.append(buffer, ~s(not json\n{"id":1}\n))

      assert [%{"id" => 1}] = messages
      assert buffer.stats.parse_errors == 1
    end

    test "handles non-object JSON as parse error" do
      buffer = MessageBuffer.new()
      {messages, buffer} = MessageBuffer.append(buffer, ~s([1,2,3]\n))

      assert messages == []
      assert buffer.stats.parse_errors == 1
    end
  end

  describe "reset/1" do
    test "clears buffer" do
      buffer = %MessageBuffer{buffer: "partial data"}
      {_, new_buffer} = MessageBuffer.reset(buffer)

      assert new_buffer.buffer == ""
    end

    test "parses remaining data if valid JSON" do
      buffer = %MessageBuffer{buffer: ~s({"final":true})}
      {messages, _buffer} = MessageBuffer.reset(buffer)

      assert [%{"final" => true}] = messages
    end

    test "returns empty if remaining data is invalid" do
      buffer = %MessageBuffer{buffer: "incomplete"}
      {messages, _buffer} = MessageBuffer.reset(buffer)

      assert messages == []
    end
  end

  describe "buffer_size/1" do
    test "returns byte size of buffer" do
      buffer = %MessageBuffer{buffer: "12345"}
      assert MessageBuffer.buffer_size(buffer) == 5
    end

    test "returns 0 for empty buffer" do
      buffer = MessageBuffer.new()
      assert MessageBuffer.buffer_size(buffer) == 0
    end
  end

  describe "stats/1" do
    test "returns stats map" do
      buffer = MessageBuffer.new()
      {_, buffer} = MessageBuffer.append(buffer, ~s({"id":1}\n))

      stats = MessageBuffer.stats(buffer)
      assert stats.messages_received == 1
      # {"id":1}\n is 9 bytes
      assert stats.bytes_received == 9
      assert stats.parse_errors == 0
    end
  end

  describe "has_pending?/1" do
    test "returns false for empty buffer" do
      buffer = MessageBuffer.new()
      refute MessageBuffer.has_pending?(buffer)
    end

    test "returns true when data is buffered" do
      buffer = %MessageBuffer{buffer: "pending"}
      assert MessageBuffer.has_pending?(buffer)
    end
  end

  describe "edge cases" do
    test "handles unicode in JSON" do
      buffer = MessageBuffer.new()
      {messages, _} = MessageBuffer.append(buffer, ~s({"emoji":"\\u2764"}\n))

      assert [%{"emoji" => "❤"}] = messages
    end

    test "handles large messages" do
      buffer = MessageBuffer.new()
      large_value = String.duplicate("x", 100_000)
      json = Jason.encode!(%{"data" => large_value}) <> "\n"

      {messages, _} = MessageBuffer.append(buffer, json)

      assert [%{"data" => ^large_value}] = messages
    end

    test "handles whitespace-only lines" do
      buffer = MessageBuffer.new()
      {messages, _} = MessageBuffer.append(buffer, "   \n\t\n{\"id\":1}\n")

      assert [%{"id" => 1}] = messages
    end
  end
end
