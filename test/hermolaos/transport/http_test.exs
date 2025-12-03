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
end
