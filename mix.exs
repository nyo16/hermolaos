defmodule Charon.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/niko/charon"

  def project do
    [
      app: :charon,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),

      # Hex.pm
      name: "Charon",
      description: "An Elixir client for the Model Context Protocol (MCP)",
      package: package(),
      docs: docs(),
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      # HTTP client
      {:req, "~> 0.5"},
      # JSON encoding/decoding
      {:jason, "~> 1.4"},
      # Option validation
      {:nimble_options, "~> 1.1"},
      # Documentation
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      # Testing
      {:mox, "~> 1.1", only: :test},
      {:bypass, "~> 2.1", only: :test}
    ]
  end

  defp package do
    [
      name: "charon",
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url
      },
      files: ~w(lib images .formatter.exs mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      name: "Charon",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: [
        "README.md",
        "LICENSE",
        "docs/architecture.md",
        "docs/design_decisions.md"
      ],
      groups_for_modules: [
        "Public API": [
          Charon
        ],
        "Protocol": [
          Charon.Protocol.Capabilities,
          Charon.Protocol.Errors,
          Charon.Protocol.JsonRpc,
          Charon.Protocol.Messages
        ],
        "Transport": [
          Charon.Transport,
          Charon.Transport.Behaviour,
          Charon.Transport.Http,
          Charon.Transport.MessageBuffer,
          Charon.Transport.Stdio
        ],
        "Client Internals": [
          Charon.Client.Connection,
          Charon.Client.NotificationHandler,
          Charon.Client.RequestTracker
        ],
        "Other": [
          Charon.Error,
          Charon.Pool
        ]
      ]
    ]
  end

  defp aliases do
    [docs: ["docs", &copy_images/1]]
  end

  defp copy_images(_) do
    File.mkdir_p!("doc/images")
    File.cp!("images/header.jpeg", "doc/images/header.jpeg")
  end
end
