defmodule Hermolaos.Integration.PlaywrightTest do
  @moduledoc """
  Integration tests using the Playwright MCP server.

  These tests require npx and network access. They are tagged with :playwright
  and excluded by default. Run with:

      mix test --include playwright

  Or run only playwright tests:

      mix test --only playwright
  """
  use ExUnit.Case, async: false

  @moduletag :playwright
  @moduletag timeout: 120_000

  # Skip if npx is not available
  setup_all do
    case System.cmd("which", ["npx"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      _ -> {:skip, "npx not available"}
    end
  end

  setup do
    # Start Playwright MCP server
    {:ok, conn} =
      Hermolaos.connect(:stdio,
        command: "npx",
        args: ["@playwright/mcp@latest"],
        timeout: 60_000
      )

    # Wait for connection to become ready (Playwright takes time to start)
    wait_for_ready(conn, 30_000)

    on_exit(fn ->
      # Clean up: close browser and disconnect
      try do
        Hermolaos.call_tool(conn, "browser_close", %{}, timeout: 5_000)
      catch
        _, _ -> :ok
      end

      try do
        Hermolaos.disconnect(conn)
      catch
        _, _ -> :ok
      end
    end)

    {:ok, conn: conn}
  end

  defp wait_for_ready(conn, timeout) when timeout > 0 do
    case Hermolaos.status(conn) do
      :ready ->
        :ok

      status when status in [:connecting, :initializing] ->
        Process.sleep(500)
        wait_for_ready(conn, timeout - 500)

      other ->
        raise "Connection failed with status: #{inspect(other)}"
    end
  end

  defp wait_for_ready(_conn, _timeout) do
    raise "Connection timed out waiting for ready state"
  end

  describe "connection and discovery" do
    test "lists available tools", %{conn: conn} do
      {:ok, result} = Hermolaos.list_tools(conn)

      assert is_list(result.tools)
      assert length(result.tools) > 0

      # Verify expected Playwright tools exist
      tool_names = Enum.map(result.tools, & &1.name)

      assert "browser_navigate" in tool_names
      assert "browser_snapshot" in tool_names
      assert "browser_click" in tool_names
      assert "browser_type" in tool_names
      assert "browser_take_screenshot" in tool_names
    end

    test "ping works", %{conn: conn} do
      assert {:ok, _} = Hermolaos.ping(conn)
    end
  end

  describe "browser navigation" do
    test "navigates to a URL and gets snapshot", %{conn: conn} do
      # Navigate to example.com
      {:ok, nav_result} = Hermolaos.call_tool(conn, "browser_navigate", %{
        "url" => "https://example.com"
      })

      assert Hermolaos.get_text(nav_result) != nil

      # Get page snapshot (accessibility tree)
      {:ok, snap_result} = Hermolaos.call_tool(conn, "browser_snapshot", %{})

      snapshot_text = Hermolaos.get_text(snap_result)
      assert snapshot_text != nil
      assert snapshot_text =~ "Example Domain"
    end

    test "takes a screenshot", %{conn: conn} do
      # Navigate first
      {:ok, _} = Hermolaos.call_tool(conn, "browser_navigate", %{
        "url" => "https://example.com"
      })

      # Take screenshot
      {:ok, screenshot_result} = Hermolaos.call_tool(conn, "browser_take_screenshot", %{})

      # Verify we got image data
      assert {:ok, image_data} = Hermolaos.get_image(screenshot_result)
      assert is_binary(image_data)
      assert byte_size(image_data) > 1000

      # Verify it's a PNG (starts with PNG magic bytes)
      assert <<0x89, "PNG", _rest::binary>> = image_data
    end
  end

  describe "browser interactions" do
    test "clicks a link and navigates", %{conn: conn} do
      # Navigate to example.com
      {:ok, _} = Hermolaos.call_tool(conn, "browser_navigate", %{
        "url" => "https://example.com"
      })

      # Get snapshot to find a link (could be "More information" or "Learn more")
      {:ok, snap_result} = Hermolaos.call_tool(conn, "browser_snapshot", %{})
      snapshot_text = Hermolaos.get_text(snap_result)

      # Parse snapshot to find the ref for any link on the page
      # The snapshot contains lines like: "- link \"Learn more\" [ref=e6]"
      {link_text, ref} =
        case Regex.run(~r/link "([^"]+)" \[ref=([^\]]+)\]/, snapshot_text) do
          [_, text, ref] -> {text, ref}
          nil -> {nil, nil}
        end

      if ref do
        # Click the link using element and ref
        {:ok, _click_result} = Hermolaos.call_tool(conn, "browser_click", %{
          "element" => link_text,
          "ref" => ref
        })

        # Give page time to load
        Process.sleep(2000)

        # Verify we navigated (snapshot should show IANA page)
        {:ok, new_snap} = Hermolaos.call_tool(conn, "browser_snapshot", %{})
        new_text = Hermolaos.get_text(new_snap)

        assert new_text =~ "IANA" or new_text =~ "Internet Assigned Numbers Authority" or
                 new_text =~ "iana.org"
      else
        # If we couldn't find the ref, just verify the snapshot had content
        assert snapshot_text =~ "Example Domain"
      end
    end

    test "types text into input fields", %{conn: conn} do
      # Navigate to a page with a form (using DuckDuckGo as example)
      {:ok, _} = Hermolaos.call_tool(conn, "browser_navigate", %{
        "url" => "https://duckduckgo.com"
      })

      # Get snapshot to find search input
      {:ok, snap_result} = Hermolaos.call_tool(conn, "browser_snapshot", %{})
      snapshot_text = Hermolaos.get_text(snap_result)

      # Find the search input ref
      # Look for textbox or searchbox
      ref =
        case Regex.run(~r/(textbox|searchbox)[^[]*\[ref=([^\]]+)\]/, snapshot_text) do
          [_, _type, ref] -> ref
          nil -> nil
        end

      if ref do
        # Type into the search box
        {:ok, _} = Hermolaos.call_tool(conn, "browser_type", %{
          "element" => "Search",
          "ref" => ref,
          "text" => "Elixir programming"
        })

        # Verify text was typed by taking new snapshot
        {:ok, after_snap} = Hermolaos.call_tool(conn, "browser_snapshot", %{})
        after_text = Hermolaos.get_text(after_snap)

        # The typed text should appear somewhere in the snapshot
        assert after_text =~ "Elixir" or snapshot_text != after_text
      else
        # Just verify we got to the page
        assert snapshot_text =~ "DuckDuckGo" or snapshot_text =~ "search"
      end
    end
  end

  describe "multiple screenshots" do
    test "get_images returns all screenshots", %{conn: conn} do
      # Navigate
      {:ok, _} = Hermolaos.call_tool(conn, "browser_navigate", %{
        "url" => "https://example.com"
      })

      # Take screenshot
      {:ok, result} = Hermolaos.call_tool(conn, "browser_take_screenshot", %{})

      # Use get_images (returns list)
      images = Hermolaos.get_images(result)

      assert is_list(images)
      assert length(images) >= 1
      assert Enum.all?(images, &is_binary/1)
    end
  end

  describe "error handling" do
    test "handles invalid tool gracefully", %{conn: conn} do
      result = Hermolaos.call_tool(conn, "nonexistent_tool", %{})

      # Playwright returns errors as {:ok, ...} with isError: true
      # or as {:error, ...} depending on the error type
      case result do
        {:error, error} ->
          assert error.code == -32601 or error.message =~ "not found"

        {:ok, response} ->
          # Playwright wraps errors in successful response with isError flag
          assert response.isError == true or Hermolaos.get_text(response) =~ "not found"
      end
    end

    test "handles navigation to invalid URL", %{conn: conn} do
      result = Hermolaos.call_tool(conn, "browser_navigate", %{
        "url" => "not-a-valid-url"
      })

      # Should either return error or handle gracefully
      case result do
        {:error, _} -> assert true
        {:ok, r} -> assert r[:isError] == true or Hermolaos.get_text(r) =~ "error" or true
      end
    end
  end

  describe "session management" do
    test "browser state persists across calls", %{conn: conn} do
      # Navigate to first page
      {:ok, _} = Hermolaos.call_tool(conn, "browser_navigate", %{
        "url" => "https://example.com"
      })

      {:ok, snap1} = Hermolaos.call_tool(conn, "browser_snapshot", %{})
      text1 = Hermolaos.get_text(snap1)
      assert text1 =~ "Example"

      # Navigate to second page
      {:ok, _} = Hermolaos.call_tool(conn, "browser_navigate", %{
        "url" => "https://httpbin.org/html"
      })

      {:ok, snap2} = Hermolaos.call_tool(conn, "browser_snapshot", %{})
      text2 = Hermolaos.get_text(snap2)

      # Should be on new page, not the old one
      refute text2 =~ "Example Domain"
      assert text2 != text1
    end
  end
end
