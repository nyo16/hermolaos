defmodule Hermolaos.Client.RequestTrackerTest do
  use ExUnit.Case, async: true

  alias Hermolaos.Client.RequestTracker

  setup do
    {:ok, tracker} = RequestTracker.start_link(timeout: 5_000)
    {:ok, tracker: tracker}
  end

  describe "next_id/1" do
    test "returns monotonically increasing IDs", %{tracker: tracker} do
      id1 = RequestTracker.next_id(tracker)
      id2 = RequestTracker.next_id(tracker)
      id3 = RequestTracker.next_id(tracker)

      assert id1 == 1
      assert id2 == 2
      assert id3 == 3
    end
  end

  describe "track/5" do
    test "tracks a request", %{tracker: tracker} do
      id = RequestTracker.next_id(tracker)
      from = {self(), make_ref()}

      :ok = RequestTracker.track(tracker, id, "tools/list", from)

      assert RequestTracker.pending?(tracker, id)
      assert RequestTracker.pending_count(tracker) == 1
    end

    test "tracks multiple requests", %{tracker: tracker} do
      for i <- 1..5 do
        id = RequestTracker.next_id(tracker)
        from = {self(), make_ref()}
        :ok = RequestTracker.track(tracker, id, "method#{i}", from)
      end

      assert RequestTracker.pending_count(tracker) == 5
    end
  end

  describe "complete/2" do
    test "completes a tracked request", %{tracker: tracker} do
      id = RequestTracker.next_id(tracker)
      from = {self(), make_ref()}

      :ok = RequestTracker.track(tracker, id, "tools/list", from)
      {:ok, ^from, "tools/list"} = RequestTracker.complete(tracker, id)

      refute RequestTracker.pending?(tracker, id)
      assert RequestTracker.pending_count(tracker) == 0
    end

    test "returns error for unknown request", %{tracker: tracker} do
      assert {:error, :not_found} = RequestTracker.complete(tracker, 999)
    end

    test "returns error if already completed", %{tracker: tracker} do
      id = RequestTracker.next_id(tracker)
      from = {self(), make_ref()}

      :ok = RequestTracker.track(tracker, id, "test", from)
      {:ok, _, _} = RequestTracker.complete(tracker, id)
      assert {:error, :not_found} = RequestTracker.complete(tracker, id)
    end
  end

  describe "fail/3" do
    test "fails a tracked request", %{tracker: tracker} do
      id = RequestTracker.next_id(tracker)
      from = {self(), make_ref()}

      :ok = RequestTracker.track(tracker, id, "tools/list", from)
      {:ok, ^from, "tools/list"} = RequestTracker.fail(tracker, id, :test_error)

      refute RequestTracker.pending?(tracker, id)
    end

    test "returns error for unknown request", %{tracker: tracker} do
      assert {:error, :not_found} = RequestTracker.fail(tracker, 999, :error)
    end
  end

  describe "cancel/2" do
    test "cancels a tracked request", %{tracker: tracker} do
      id = RequestTracker.next_id(tracker)
      from = {self(), make_ref()}

      :ok = RequestTracker.track(tracker, id, "test", from)
      :ok = RequestTracker.cancel(tracker, id)

      refute RequestTracker.pending?(tracker, id)
    end

    test "returns ok for unknown request", %{tracker: tracker} do
      assert :ok = RequestTracker.cancel(tracker, 999)
    end
  end

  describe "fail_all/2" do
    test "fails all pending requests", %{tracker: tracker} do
      froms =
        for i <- 1..3 do
          id = RequestTracker.next_id(tracker)
          from = {self(), make_ref()}
          :ok = RequestTracker.track(tracker, id, "method#{i}", from)
          {from, "method#{i}"}
        end

      failed = RequestTracker.fail_all(tracker, :connection_closed)

      assert length(failed) == 3
      assert RequestTracker.pending_count(tracker) == 0

      for {from, method} <- froms do
        assert {from, method} in failed
      end
    end

    test "returns empty list when no pending requests", %{tracker: tracker} do
      assert [] = RequestTracker.fail_all(tracker, :error)
    end
  end

  describe "stats/1" do
    test "tracks request statistics", %{tracker: tracker} do
      # Track some requests
      id1 = RequestTracker.next_id(tracker)
      from1 = {self(), make_ref()}
      :ok = RequestTracker.track(tracker, id1, "test1", from1)

      id2 = RequestTracker.next_id(tracker)
      from2 = {self(), make_ref()}
      :ok = RequestTracker.track(tracker, id2, "test2", from2)

      id3 = RequestTracker.next_id(tracker)
      from3 = {self(), make_ref()}
      :ok = RequestTracker.track(tracker, id3, "test3", from3)

      # Complete one
      RequestTracker.complete(tracker, id1)

      # Fail one
      RequestTracker.fail(tracker, id2, :error)

      # Cancel one
      RequestTracker.cancel(tracker, id3)

      stats = RequestTracker.stats(tracker)

      assert stats.requests_tracked == 3
      assert stats.requests_completed == 1
      assert stats.requests_failed == 1
      assert stats.requests_cancelled == 1
    end
  end

  describe "timeout behavior" do
    test "times out and replies with error", %{tracker: _tracker} do
      # Start tracker with very short timeout
      {:ok, tracker} = RequestTracker.start_link(timeout: 50)

      id = RequestTracker.next_id(tracker)
      # Use self() to receive the timeout reply
      from = {self(), make_ref()}

      :ok = RequestTracker.track(tracker, id, "slow_method", from)

      # Wait for timeout
      assert_receive {_ref, {:error, %Hermolaos.Protocol.Errors{code: -32001}}}, 200

      # Request should no longer be pending
      refute RequestTracker.pending?(tracker, id)

      stats = RequestTracker.stats(tracker)
      assert stats.requests_timed_out == 1
    end

    test "custom timeout per request" do
      {:ok, tracker} = RequestTracker.start_link(timeout: 60_000)

      id = RequestTracker.next_id(tracker)
      from = {self(), make_ref()}

      # Track with short custom timeout
      :ok = RequestTracker.track(tracker, id, "fast_timeout", from, 50)

      assert_receive {_ref, {:error, %Hermolaos.Protocol.Errors{code: -32001}}}, 200
    end

    test "completing before timeout cancels timer" do
      {:ok, tracker} = RequestTracker.start_link(timeout: 100)

      id = RequestTracker.next_id(tracker)
      from = {self(), make_ref()}

      :ok = RequestTracker.track(tracker, id, "test", from)
      {:ok, _, _} = RequestTracker.complete(tracker, id)

      # Wait past timeout - should not receive error
      refute_receive {_ref, {:error, _}}, 200
    end
  end
end
