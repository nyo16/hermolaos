defmodule CharonTest do
  use ExUnit.Case
  doctest Charon

  describe "module exports" do
    test "public API functions are defined" do
      # Verify main API functions exist
      assert function_exported?(Charon, :connect, 2)
      assert function_exported?(Charon, :disconnect, 1)
      assert function_exported?(Charon, :list_tools, 1)
      assert function_exported?(Charon, :call_tool, 3)
      assert function_exported?(Charon, :list_resources, 1)
      assert function_exported?(Charon, :read_resource, 2)
      assert function_exported?(Charon, :list_prompts, 1)
      assert function_exported?(Charon, :get_prompt, 3)
      assert function_exported?(Charon, :ping, 1)
    end
  end

  describe "get_text/1" do
    test "extracts text from single text content" do
      result = %{content: [%{type: "text", text: "Hello world"}]}
      assert Charon.get_text(result) == "Hello world"
    end

    test "concatenates multiple text items" do
      result = %{content: [
        %{type: "text", text: "Line 1"},
        %{type: "text", text: "Line 2"}
      ]}
      assert Charon.get_text(result) == "Line 1\nLine 2"
    end

    test "ignores non-text content" do
      result = %{content: [
        %{type: "text", text: "Hello"},
        %{type: "image", data: "base64data"}
      ]}
      assert Charon.get_text(result) == "Hello"
    end

    test "returns nil for no text content" do
      result = %{content: [%{type: "image", data: "base64data"}]}
      assert Charon.get_text(result) == nil
    end

    test "returns nil for invalid input" do
      assert Charon.get_text(%{}) == nil
      assert Charon.get_text(nil) == nil
    end
  end

  describe "get_image/1" do
    test "extracts and decodes image data" do
      # "Hello" in base64
      base64_data = Base.encode64("Hello")
      result = %{content: [%{type: "image", data: base64_data}]}
      assert Charon.get_image(result) == {:ok, "Hello"}
    end

    test "returns first image when multiple present" do
      data1 = Base.encode64("First")
      data2 = Base.encode64("Second")
      result = %{content: [
        %{type: "image", data: data1},
        %{type: "image", data: data2}
      ]}
      assert Charon.get_image(result) == {:ok, "First"}
    end

    test "skips non-image content" do
      data = Base.encode64("ImageData")
      result = %{content: [
        %{type: "text", text: "Description"},
        %{type: "image", data: data}
      ]}
      assert Charon.get_image(result) == {:ok, "ImageData"}
    end

    test "returns error for no image content" do
      result = %{content: [%{type: "text", text: "No image"}]}
      assert Charon.get_image(result) == :error
    end

    test "returns error for invalid input" do
      assert Charon.get_image(%{}) == :error
      assert Charon.get_image(nil) == :error
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
      assert Charon.get_images(result) == ["First", "Second"]
    end

    test "returns empty list for no images" do
      result = %{content: [%{type: "text", text: "No images"}]}
      assert Charon.get_images(result) == []
    end

    test "returns empty list for invalid input" do
      assert Charon.get_images(%{}) == []
      assert Charon.get_images(nil) == []
    end
  end
end
