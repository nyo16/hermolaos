defmodule Hermolaos.MixProject do
  use Mix.Project

  @version "0.3.0"
  @source_url "https://github.com/nyo16/hermolaos"

  def project do
    [
      app: :hermolaos,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),

      # Hex.pm
      name: "Hermolaos",
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
      name: "hermolaos",
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
      name: "Hermolaos",
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
          Hermolaos
        ],
        "Protocol": [
          Hermolaos.Protocol.Capabilities,
          Hermolaos.Protocol.Errors,
          Hermolaos.Protocol.JsonRpc,
          Hermolaos.Protocol.Messages
        ],
        "Transport": [
          Hermolaos.Transport,
          Hermolaos.Transport.Behaviour,
          Hermolaos.Transport.Http,
          Hermolaos.Transport.MessageBuffer,
          Hermolaos.Transport.Stdio
        ],
        "Client Internals": [
          Hermolaos.Client.Connection,
          Hermolaos.Client.NotificationHandler,
          Hermolaos.Client.RequestTracker
        ],
        "Other": [
          Hermolaos.Error,
          Hermolaos.Pool
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
