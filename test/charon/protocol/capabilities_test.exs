defmodule Charon.Protocol.CapabilitiesTest do
  use ExUnit.Case, async: true

  alias Charon.Protocol.Capabilities

  describe "default_client_capabilities/0" do
    test "returns default client capabilities" do
      caps = Capabilities.default_client_capabilities()

      assert is_map(caps)
      assert Map.has_key?(caps, "roots")
      assert caps["roots"]["listChanged"] == true
    end
  end

  describe "client_capabilities_with_sampling/0" do
    test "returns capabilities with sampling enabled" do
      caps = Capabilities.client_capabilities_with_sampling()

      assert Map.has_key?(caps, "roots")
      assert Map.has_key?(caps, "sampling")
    end
  end

  describe "build_client_capabilities/1" do
    test "returns default capabilities with no options" do
      caps = Capabilities.build_client_capabilities()

      assert Map.has_key?(caps, "roots")
      assert caps["roots"]["listChanged"] == true
    end

    test "enables sampling when requested" do
      caps = Capabilities.build_client_capabilities(sampling: true)

      assert Map.has_key?(caps, "sampling")
    end

    test "disables roots when requested" do
      caps = Capabilities.build_client_capabilities(roots: false)

      refute Map.has_key?(caps, "roots")
    end
  end

  describe "supports?/2" do
    test "returns true when capability exists" do
      caps = %{"tools" => %{}, "resources" => %{"subscribe" => true}}

      assert Capabilities.supports?(caps, :tools)
      assert Capabilities.supports?(caps, :resources)
    end

    test "returns false when capability missing" do
      caps = %{"tools" => %{}}

      refute Capabilities.supports?(caps, :resources)
      refute Capabilities.supports?(caps, :prompts)
    end
  end

  describe "supports_list_changed?/2" do
    test "returns true when listChanged is true" do
      caps = %{"tools" => %{"listChanged" => true}}

      assert Capabilities.supports_list_changed?(caps, :tools)
    end

    test "returns false when listChanged is missing" do
      caps = %{"tools" => %{}}

      refute Capabilities.supports_list_changed?(caps, :tools)
    end

    test "returns false when capability is missing" do
      caps = %{}

      refute Capabilities.supports_list_changed?(caps, :tools)
    end
  end

  describe "supports_subscribe?/1" do
    test "returns true when resources support subscribe" do
      caps = %{"resources" => %{"subscribe" => true}}

      assert Capabilities.supports_subscribe?(caps)
    end

    test "returns false when subscribe not supported" do
      caps = %{"resources" => %{}}

      refute Capabilities.supports_subscribe?(caps)
    end

    test "returns false when resources missing" do
      caps = %{}

      refute Capabilities.supports_subscribe?(caps)
    end
  end

  describe "from_init_response/1" do
    test "extracts capabilities from init response" do
      response = %{"capabilities" => %{"tools" => %{}}}

      assert {:ok, %{"tools" => %{}}} = Capabilities.from_init_response(response)
    end

    test "returns error when capabilities missing" do
      response = %{"serverInfo" => %{}}

      assert {:error, :missing_capabilities} = Capabilities.from_init_response(response)
    end
  end

  describe "server_info_from_response/1" do
    test "extracts server info from response" do
      response = %{"serverInfo" => %{"name" => "Test", "version" => "1.0"}}

      assert {:ok, %{"name" => "Test", "version" => "1.0"}} =
               Capabilities.server_info_from_response(response)
    end

    test "returns error when server info missing" do
      response = %{"capabilities" => %{}}

      assert {:error, :missing_server_info} = Capabilities.server_info_from_response(response)
    end
  end

  describe "protocol_version_from_response/1" do
    test "extracts protocol version from response" do
      response = %{"protocolVersion" => "2025-03-26"}

      assert {:ok, "2025-03-26"} = Capabilities.protocol_version_from_response(response)
    end

    test "returns error when version missing" do
      response = %{}

      assert {:error, :missing_version} = Capabilities.protocol_version_from_response(response)
    end
  end

  describe "supported_versions/0" do
    test "returns list of supported versions" do
      versions = Capabilities.supported_versions()

      assert is_list(versions)
      assert "2025-03-26" in versions
    end
  end

  describe "version_supported?/1" do
    test "returns true for supported version" do
      assert Capabilities.version_supported?("2025-03-26")
    end

    test "returns false for unsupported version" do
      refute Capabilities.version_supported?("1.0.0")
    end
  end

  describe "latest_version/0" do
    test "returns a supported version" do
      version = Capabilities.latest_version()

      assert Capabilities.version_supported?(version)
    end
  end

  describe "require/2" do
    test "returns :ok when all capabilities present" do
      caps = %{"tools" => %{}, "resources" => %{}}

      assert :ok = Capabilities.require(caps, [:tools, :resources])
    end

    test "returns error for missing capability" do
      caps = %{"tools" => %{}}

      assert {:error, {:missing_capability, :resources}} =
               Capabilities.require(caps, [:tools, :resources])
    end

    test "returns :ok for empty required list" do
      caps = %{}

      assert :ok = Capabilities.require(caps, [])
    end
  end
end
