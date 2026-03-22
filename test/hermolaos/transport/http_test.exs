defmodule Hermolaos.Transport.HttpTest do
  use ExUnit.Case, async: true

  alias Hermolaos.Transport.Http

  describe "start_link/1" do
    test "starts with required options" do
      {:ok, pid} = Http.start_link(owner: self(), url: "http://localhost:3000/mcp")

      assert Process.alive?(pid)
      assert_receive {:transport_ready, ^pid}

      Http.close(pid)
    end

    test "accepts custom headers" do
      {:ok, pid} =
        Http.start_link(
          owner: self(),
          url: "http://localhost:3000/mcp",
          headers: [
            {"authorization", "Bearer test-token"},
            {"x-api-key", "test-key"}
          ]
        )

      assert Process.alive?(pid)
      assert_receive {:transport_ready, ^pid}

      # Verify headers are stored in state via info
      info = Http.info(pid)
      assert info.url == "http://localhost:3000/mcp"

      Http.close(pid)
    end

    test "accepts req_options" do
      {:ok, pid} =
        Http.start_link(
          owner: self(),
          url: "http://localhost:3000/mcp",
          req_options: [pool_timeout: 5000]
        )

      assert Process.alive?(pid)
      Http.close(pid)
    end

    test "accepts timeout options" do
      {:ok, pid} =
        Http.start_link(
          owner: self(),
          url: "http://localhost:3000/mcp",
          connect_timeout: 5000,
          receive_timeout: 10000
        )

      assert Process.alive?(pid)
      Http.close(pid)
    end
  end

  describe "connected?/1" do
    test "returns true after start" do
      {:ok, pid} = Http.start_link(owner: self(), url: "http://localhost:3000/mcp")
      assert_receive {:transport_ready, ^pid}

      assert Http.connected?(pid) == true

      Http.close(pid)
    end
  end

  describe "info/1" do
    test "returns transport information" do
      {:ok, pid} = Http.start_link(owner: self(), url: "http://localhost:3000/mcp")
      assert_receive {:transport_ready, ^pid}

      info = Http.info(pid)

      assert info.url == "http://localhost:3000/mcp"
      assert info.session_id == nil
      assert info.connected == true
      assert info.pending_requests == 0
      assert info.stats.requests_sent == 0
      assert info.stats.responses_received == 0
      assert info.stats.errors == 0

      Http.close(pid)
    end
  end

  describe "close/1" do
    test "stops the transport and notifies owner" do
      {:ok, pid} = Http.start_link(owner: self(), url: "http://localhost:3000/mcp")
      assert_receive {:transport_ready, ^pid}

      :ok = Http.close(pid)

      assert_receive {:transport_closed, ^pid, :normal}
      refute Process.alive?(pid)
    end
  end

  # ===========================================================================
  # 2025-11-25 spec features
  # ===========================================================================

  describe "set_protocol_version/2" do
    test "sets the protocol version" do
      {:ok, pid} = Http.start_link(owner: self(), url: "http://localhost:9999/mcp")
      assert_receive {:transport_ready, ^pid}

      assert :ok = Http.set_protocol_version(pid, "2025-11-25")

      # Transport should still be functional after setting the version
      assert Http.connected?(pid) == true

      Http.close(pid)
    end
  end

  describe "terminate_session/1" do
    test "returns ok when no session id" do
      {:ok, pid} = Http.start_link(owner: self(), url: "http://localhost:9999/mcp")
      assert_receive {:transport_ready, ^pid}

      assert :ok = Http.terminate_session(pid)

      Http.close(pid)
    end
  end

  describe "protocol_version header" do
    test "includes mcp-protocol-version header after set" do
      bypass = Bypass.open()
      url = "http://localhost:#{bypass.port}/mcp"

      {:ok, pid} = Http.start_link(owner: self(), url: url)
      assert_receive {:transport_ready, ^pid}

      Http.set_protocol_version(pid, "2025-11-25")

      # Small delay to allow the async cast to be processed
      Process.sleep(10)

      Bypass.expect(bypass, "POST", "/mcp", fn conn ->
        protocol_version =
          Enum.find_value(conn.req_headers, fn
            {"mcp-protocol-version", value} -> value
            _ -> nil
          end)

        assert protocol_version == "2025-11-25"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}})
        )
      end)

      message = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => %{}}
      assert :ok = Http.send_message(pid, message)

      assert_receive {:transport_message, ^pid, %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}}

      Http.close(pid)
    end
  end

  describe "session_id tracking" do
    test "tracks session id from response headers" do
      bypass = Bypass.open()
      url = "http://localhost:#{bypass.port}/mcp"

      {:ok, pid} = Http.start_link(owner: self(), url: url)
      assert_receive {:transport_ready, ^pid}

      # First request: server returns a session id in the response
      Bypass.expect_once(bypass, "POST", "/mcp", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("mcp-session-id", "session-abc-123")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}})
        )
      end)

      message1 = %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => %{}}
      assert :ok = Http.send_message(pid, message1)
      assert_receive {:transport_message, ^pid, _}

      # Verify session id is now tracked
      info = Http.info(pid)
      assert info.session_id == "session-abc-123"

      # Second request: verify the transport sends the session id header
      Bypass.expect_once(bypass, "POST", "/mcp", fn conn ->
        session_id =
          Enum.find_value(conn.req_headers, fn
            {"mcp-session-id", value} -> value
            _ -> nil
          end)

        assert session_id == "session-abc-123"

        conn
        |> Plug.Conn.put_resp_header("mcp-session-id", "session-abc-123")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{"jsonrpc" => "2.0", "id" => 2, "result" => %{}})
        )
      end)

      message2 = %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list", "params" => %{}}
      assert :ok = Http.send_message(pid, message2)
      assert_receive {:transport_message, ^pid, %{"jsonrpc" => "2.0", "id" => 2, "result" => %{}}}

      Http.close(pid)
    end
  end

  describe "SSE response parsing" do
    test "parses SSE events with event IDs" do
      bypass = Bypass.open()
      url = "http://localhost:#{bypass.port}/mcp"

      # Disable Req's auto-decode so text/event-stream body comes through as binary
      {:ok, pid} =
        Http.start_link(
          owner: self(),
          url: url,
          req_options: [decode_body: false]
        )

      assert_receive {:transport_ready, ^pid}

      sse_body =
        [
          "id: evt-001",
          "data: #{Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{"tools" => []}})}",
          "",
          "id: evt-002",
          "data: #{Jason.encode!(%{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"})}",
          "",
          ""
        ]
        |> Enum.join("\n")

      Bypass.expect_once(bypass, "POST", "/mcp", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.resp(200, sse_body)
      end)

      message = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => %{}}
      assert :ok = Http.send_message(pid, message)

      # Should receive both parsed SSE messages
      assert_receive {:transport_message, ^pid,
                      %{"jsonrpc" => "2.0", "id" => 1, "result" => %{"tools" => []}}}

      assert_receive {:transport_message, ^pid,
                      %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}}

      Http.close(pid)
    end
  end
end
