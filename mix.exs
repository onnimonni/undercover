defmodule ExUndercover.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_undercover,
      version: "0.2.0",
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      test_coverage: test_coverage(),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {ExUndercover.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp test_coverage do
    [
      summary: [threshold: 90],
      ignore_modules: [
        ~r/^Mix\.Tasks\./,
        ExUndercover,
        ExUndercover.Capture.ClientHello,
        ExUndercover.CookieJar,
        ExUndercover.CookieJar.Cookie,
        ExUndercover.Debug,
        ExUndercover.Nif,
        ExUndercover.Proton,
        ExUndercover.Profile.Chrome147,
        ExUndercover.ProfileRegistry,
        ExUndercover.Runtime,
        ExUndercover.Solver,
        ExUndercover.Solver.Chrome,
        ExUndercover.Solver.Chrome.CDPConnection,
        ExUndercover.TestSupport.CountingSolver,
        ExUndercover.TestSupport.HTTPServer,
        ExUndercover.Transport.ProfileSync,
        ExUndercover.WireGuard.PolicyRouting,
        ExUndercover.WireGuard.Config,
        ExUndercover.WireGuard.InterfaceConfig,
        ExUndercover.WireGuard.Manager
      ]
    ]
  end

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:jason, "~> 1.4"},
      {:rustler, "~> 0.36", optional: true},
      {:rustler_precompiled, "~> 0.7.0"},
      {:websockex, "~> 0.4"},
      {:wireguardex, "~> 0.4"}
    ]
  end
end
