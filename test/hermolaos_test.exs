defmodule HermolaosTest do
  use ExUnit.Case
  doctest Hermolaos

  describe "module exports" do
    test "public API functions are defined" do
      # Verify main API functions exist
      assert function_exported?(Hermolaos, :connect, 2)
      assert function_exported?(Hermolaos, :disconnect, 1)
      assert function_exported?(Hermolaos, :list_tools, 1)
      assert function_exported?(Hermolaos, :call_tool, 3)
      assert function_exported?(Hermolaos, :list_resources, 1)
      assert function_exported?(Hermolaos, :read_resource, 2)
      assert function_exported?(Hermolaos, :list_prompts, 1)
      assert function_exported?(Hermolaos, :get_prompt, 3)
      assert function_exported?(Hermolaos, :ping, 1)
    end
  end

  describe "connect/2 with HTTP transport" do
    # Note: These tests verify that the options are accepted and passed through.
    # The actual header usage is tested in transport/http_test.exs

    test "accepts headers option" do
      # Use the transport directly to avoid connection initialization issues
      {:ok, pid} =
        Hermolaos.Transport.Http.start_link(
          owner: self(),
          url: "http://localhost:9999/mcp",
          headers: [
            {"authorization", "Bearer test-token"},
            {"x-api-key", "test-api-key"}
          ]
        )

      # Transport should start and report ready
      assert_receive {:transport_ready, ^pid}

      # Verify it's running with our headers
      info = Hermolaos.Transport.Http.info(pid)
      assert info.url == "http://localhost:9999/mcp"

      Hermolaos.Transport.Http.close(pid)
    end

    test "accepts empty headers" do
      {:ok, pid} =
        Hermolaos.Transport.Http.start_link(
          owner: self(),
          url: "http://localhost:9999/mcp",
          headers: []
        )

      assert_receive {:transport_ready, ^pid}
      Hermolaos.Transport.Http.close(pid)
    end

    test "works without headers option" do
      {:ok, pid} =
        Hermolaos.Transport.Http.start_link(
          owner: self(),
          url: "http://localhost:9999/mcp"
        )

      assert_receive {:transport_ready, ^pid}
      Hermolaos.Transport.Http.close(pid)
    end
  end

  describe "get_text/1" do
    test "extracts text from single text content" do
      result = %{content: [%{type: "text", text: "Hello world"}]}
      assert Hermolaos.get_text(result) == "Hello world"
    end

    test "concatenates multiple text items" do
      result = %{content: [
        %{type: "text", text: "Line 1"},
        %{type: "text", text: "Line 2"}
      ]}
      assert Hermolaos.get_text(result) == "Line 1\nLine 2"
    end

    test "ignores non-text content" do
      result = %{content: [
        %{type: "text", text: "Hello"},
        %{type: "image", data: "base64data"}
      ]}
      assert Hermolaos.get_text(result) == "Hello"
    end

    test "returns nil for no text content" do
      result = %{content: [%{type: "image", data: "base64data"}]}
      assert Hermolaos.get_text(result) == nil
    end

    test "returns nil for invalid input" do
      assert Hermolaos.get_text(%{}) == nil
      assert Hermolaos.get_text(nil) == nil
    end
  end

  describe "get_image/1" do
    test "extracts and decodes image data" do
      # "Hello" in base64
      base64_data = Base.encode64("Hello")
      result = %{content: [%{type: "image", data: base64_data}]}
      assert Hermolaos.get_image(result) == {:ok, "Hello"}
    end

    test "returns first image when multiple present" do
      data1 = Base.encode64("First")
      data2 = Base.encode64("Second")
      result = %{content: [
        %{type: "image", data: data1},
        %{type: "image", data: data2}
      ]}
      assert Hermolaos.get_image(result) == {:ok, "First"}
    end

    test "skips non-image content" do
      data = Base.encode64("ImageData")
      result = %{content: [
        %{type: "text", text: "Description"},
        %{type: "image", data: data}
      ]}
      assert Hermolaos.get_image(result) == {:ok, "ImageData"}
    end

    test "returns error for no image content" do
      result = %{content: [%{type: "text", text: "No image"}]}
      assert Hermolaos.get_image(result) == :error
    end

    test "returns error for invalid input" do
      assert Hermolaos.get_image(%{}) == :error
      assert Hermolaos.get_image(nil) == :error
    end
  end

  describe "get_images/1" do
    test "extracts all images" do
      data1 = Base.encode64("First")
      data2 = Base.encode64("Second")
      result = %{content: [
        %{type: "image", data: data1},
        %{type: "text", text: "Middle"},
        %{type: "image", data: data2}
      ]}
      assert Hermolaos.get_images(result) == ["First", "Second"]
    end

    test "returns empty list for no images" do
      result = %{content: [%{type: "text", text: "No images"}]}
      assert Hermolaos.get_images(result) == []
    end

    test "returns empty list for invalid input" do
      assert Hermolaos.get_images(%{}) == []
      assert Hermolaos.get_images(nil) == []
    end
  end
end
