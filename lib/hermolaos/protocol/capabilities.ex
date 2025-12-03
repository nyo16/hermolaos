defmodule Hermolaos.Protocol.Capabilities do
  @moduledoc """
  MCP capability negotiation and validation.

  Capabilities define what features a client or server supports. During
  the initialization handshake, both parties exchange their capabilities
  to establish what operations are available.

  ## Client Capabilities

  Clients can advertise these capabilities:

  - `roots` - Filesystem root access
    - `listChanged` - Whether client sends notifications when roots change
  - `sampling` - LLM sampling support (allows server to request text generation)

  ## Server Capabilities

  Servers can advertise these capabilities:

  - `tools` - Tool invocation support
    - `listChanged` - Whether server sends notifications when tools change
  - `resources` - Resource access support
    - `subscribe` - Whether subscriptions are supported
    - `listChanged` - Whether server sends notifications when resources change
  - `prompts` - Prompt template support
    - `listChanged` - Whether server sends notifications when prompts change
  - `logging` - Structured logging support
  - `completions` - Argument completion support

  ## Example

      # Default client capabilities
      caps = Hermolaos.Protocol.Capabilities.default_client_capabilities()

      # Check if server supports tools
      if Hermolaos.Protocol.Capabilities.supports?(server_caps, :tools) do
        # Can list and call tools
      end
  """

  @type client_capabilities :: %{
          optional(:roots) => %{optional(:listChanged) => boolean()},
          optional(:sampling) => %{}
        }

  @type server_capabilities :: %{
          optional(:tools) => %{optional(:listChanged) => boolean()},
          optional(:resources) => %{
            optional(:subscribe) => boolean(),
            optional(:listChanged) => boolean()
          },
          optional(:prompts) => %{optional(:listChanged) => boolean()},
          optional(:logging) => %{},
          optional(:completions) => %{}
        }

  @type capability :: :roots | :sampling | :tools | :resources | :prompts | :logging | :completions

  # ============================================================================
  # Default Capabilities
  # ============================================================================

  @doc """
  Returns default client capabilities.

  The default client advertises:
  - `roots` with `listChanged: true`

  Sampling is not enabled by default as it requires special handling.

  ## Examples

      caps = Hermolaos.Protocol.Capabilities.default_client_capabilities()
      # => %{"roots" => %{"listChanged" => true}}
  """
  @spec default_client_capabilities() :: client_capabilities()
  def default_client_capabilities do
    %{
      "roots" => %{
        "listChanged" => true
      }
    }
  end

  @doc """
  Returns client capabilities with sampling support enabled.

  ## Examples

      caps = Hermolaos.Protocol.Capabilities.client_capabilities_with_sampling()
      # => %{"roots" => %{"listChanged" => true}, "sampling" => %{}}
  """
  @spec client_capabilities_with_sampling() :: client_capabilities()
  def client_capabilities_with_sampling do
    default_client_capabilities()
    |> Map.put("sampling", %{})
  end

  @doc """
  Builds custom client capabilities.

  ## Options

  - `:roots` - Enable roots capability (default: true)
  - `:roots_list_changed` - Enable roots change notifications (default: true)
  - `:sampling` - Enable sampling capability (default: false)

  ## Examples

      caps = Hermolaos.Protocol.Capabilities.build_client_capabilities(
        roots: true,
        sampling: true
      )
  """
  @spec build_client_capabilities(keyword()) :: client_capabilities()
  def build_client_capabilities(opts \\ []) do
    caps = %{}

    caps =
      if Keyword.get(opts, :roots, true) do
        roots = %{}

        roots =
          if Keyword.get(opts, :roots_list_changed, true) do
            Map.put(roots, "listChanged", true)
          else
            roots
          end

        Map.put(caps, "roots", roots)
      else
        caps
      end

    caps =
      if Keyword.get(opts, :sampling, false) do
        Map.put(caps, "sampling", %{})
      else
        caps
      end

    caps
  end

  # ============================================================================
  # Capability Checking
  # ============================================================================

  @doc """
  Checks if capabilities include support for a specific feature.

  ## Examples

      iex> caps = %{"tools" => %{"listChanged" => true}}
      iex> Hermolaos.Protocol.Capabilities.supports?(caps, :tools)
      true

      iex> caps = %{}
      iex> Hermolaos.Protocol.Capabilities.supports?(caps, :tools)
      false
  """
  @spec supports?(map(), capability()) :: boolean()
  def supports?(capabilities, feature) when is_map(capabilities) do
    key = capability_key(feature)
    Map.has_key?(capabilities, key)
  end

  @doc """
  Checks if a capability supports change notifications.

  ## Examples

      iex> caps = %{"tools" => %{"listChanged" => true}}
      iex> Hermolaos.Protocol.Capabilities.supports_list_changed?(caps, :tools)
      true

      iex> caps = %{"tools" => %{}}
      iex> Hermolaos.Protocol.Capabilities.supports_list_changed?(caps, :tools)
      false
  """
  @spec supports_list_changed?(map(), capability()) :: boolean()
  def supports_list_changed?(capabilities, feature) when is_map(capabilities) do
    key = capability_key(feature)

    case Map.get(capabilities, key) do
      %{"listChanged" => true} -> true
      _ -> false
    end
  end

  @doc """
  Checks if resource capabilities support subscriptions.

  ## Examples

      iex> caps = %{"resources" => %{"subscribe" => true}}
      iex> Hermolaos.Protocol.Capabilities.supports_subscribe?(caps)
      true
  """
  @spec supports_subscribe?(map()) :: boolean()
  def supports_subscribe?(capabilities) when is_map(capabilities) do
    case Map.get(capabilities, "resources") do
      %{"subscribe" => true} -> true
      _ -> false
    end
  end

  # ============================================================================
  # Capability Extraction
  # ============================================================================

  @doc """
  Extracts capabilities from an initialize response.

  ## Examples

      response = %{"capabilities" => %{"tools" => %{}}, "serverInfo" => %{...}}
      {:ok, caps} = Hermolaos.Protocol.Capabilities.from_init_response(response)
  """
  @spec from_init_response(map()) :: {:ok, map()} | {:error, :missing_capabilities}
  def from_init_response(%{"capabilities" => caps}) when is_map(caps) do
    {:ok, caps}
  end

  def from_init_response(_), do: {:error, :missing_capabilities}

  @doc """
  Extracts server info from an initialize response.

  ## Examples

      response = %{"serverInfo" => %{"name" => "MyServer", "version" => "1.0.0"}}
      {:ok, info} = Hermolaos.Protocol.Capabilities.server_info_from_response(response)
  """
  @spec server_info_from_response(map()) :: {:ok, map()} | {:error, :missing_server_info}
  def server_info_from_response(%{"serverInfo" => info}) when is_map(info) do
    {:ok, info}
  end

  def server_info_from_response(_), do: {:error, :missing_server_info}

  @doc """
  Extracts the protocol version from an initialize response.

  ## Examples

      response = %{"protocolVersion" => "2025-03-26"}
      {:ok, version} = Hermolaos.Protocol.Capabilities.protocol_version_from_response(response)
  """
  @spec protocol_version_from_response(map()) :: {:ok, String.t()} | {:error, :missing_version}
  def protocol_version_from_response(%{"protocolVersion" => version}) when is_binary(version) do
    {:ok, version}
  end

  def protocol_version_from_response(_), do: {:error, :missing_version}

  # ============================================================================
  # Protocol Version Support
  # ============================================================================

  @supported_versions ["2025-03-26", "2025-06-18", "2025-11-25", "2024-11-05"]

  @doc """
  Returns the list of supported protocol versions.
  """
  @spec supported_versions() :: [String.t()]
  def supported_versions, do: @supported_versions

  @doc """
  Checks if a protocol version is supported.

  ## Examples

      iex> Hermolaos.Protocol.Capabilities.version_supported?("2025-03-26")
      true

      iex> Hermolaos.Protocol.Capabilities.version_supported?("1.0.0")
      false
  """
  @spec version_supported?(String.t()) :: boolean()
  def version_supported?(version) when is_binary(version) do
    version in @supported_versions
  end

  @doc """
  Returns the latest (preferred) protocol version.
  """
  @spec latest_version() :: String.t()
  def latest_version, do: hd(@supported_versions)

  # ============================================================================
  # Capability Validation
  # ============================================================================

  @doc """
  Validates that required capabilities are present for an operation.

  ## Examples

      # Check if we can list tools
      :ok = Hermolaos.Protocol.Capabilities.require(server_caps, [:tools])

      # Check if we can subscribe to resources
      {:error, {:missing_capability, :resources}} =
        Hermolaos.Protocol.Capabilities.require(%{}, [:resources])
  """
  @spec require(map(), [capability()]) :: :ok | {:error, {:missing_capability, capability()}}
  def require(capabilities, required) when is_map(capabilities) and is_list(required) do
    Enum.reduce_while(required, :ok, fn cap, :ok ->
      if supports?(capabilities, cap) do
        {:cont, :ok}
      else
        {:halt, {:error, {:missing_capability, cap}}}
      end
    end)
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp capability_key(:roots), do: "roots"
  defp capability_key(:sampling), do: "sampling"
  defp capability_key(:tools), do: "tools"
  defp capability_key(:resources), do: "resources"
  defp capability_key(:prompts), do: "prompts"
  defp capability_key(:logging), do: "logging"
  defp capability_key(:completions), do: "completions"
end
