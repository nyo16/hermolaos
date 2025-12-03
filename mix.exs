defmodule Charon.MixProject do
  use Mix.Project

  def project do
    [
      app: :charon,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
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
end
