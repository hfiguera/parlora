defmodule Parlora.MixProject do
  use Mix.Project

  def project do
    if String.to_integer(System.otp_release()) < 27 do
      Mix.raise("Parlora requires Erlang/OTP 27 or later")
    end

    [
      app: :parlora,
      name: "Parlora",
      version: "0.2.0",
      source_url: "https://github.com/hfiguera/parlora",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      docs: docs(),
      description: "An Elixir framework for building real-time voice AI agents",
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/hfiguera/parlora"},
        files:
          ~w(lib native/*/src native/*/Cargo.toml native/*/Cargo.lock native/*/build.rs mix.exs mix.lock README.md CHANGELOG.md LICENSE docs/public-interfaces.md docs/observability.md docs/first-session.md docs/using-parlora.md docs/beam-compatibility.md docs/output-recovery.md docs/openai-provider.md docs/gemini-provider.md docs/grok-provider.md docs/jido-backend.md docs/sagents-backend.md docs/legion-backend.md docs/browser-channel.md docs/twilio-channel.md docs/telnyx-channel.md examples/order_desk/README.md examples/order_desk/APPLICATION.md scripts/install_opus.sh rust-toolchain.toml)
      ],
      dialyzer: [
        plt_add_apps:
          [:mix, :credence] ++ if(Mix.env() == :test, do: [:ex_unit, :stream_data], else: [])
      ],
      test_coverage: [summary: [threshold: 80]]
    ]
  end

  def cli, do: [preferred_envs: [ci: :test]]

  def application do
    [extra_applications: [:logger, :ssl], mod: {Parlora.Application, []}]
  end

  defp elixirc_paths(:test), do: ["lib", "dev", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "dev"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:ex_webrtc, "~> 0.17.0"},
      {:bandit, "~> 1.13 and >= 1.13.1"},
      {:plug, "~> 1.20 and >= 1.20.3"},
      {:websock_adapter, "~> 0.6.0"},
      {:websock, "~> 0.5.3"},
      {:mint, "~> 1.11"},
      {:mint_web_socket, "~> 1.0 and >= 1.0.6"},
      {:rustler, "~> 0.38.0", runtime: false},
      {:jido, "~> 2.4.0", optional: true},
      {:sagents, "~> 0.17.1", optional: true},
      {:legion, "~> 0.6.0", optional: true},
      {:telemetry, "~> 1.4 and >= 1.4.2"},
      {:ex_doc, "== 0.40.4", only: :dev, runtime: false},
      {:stream_data, "== 1.4.0", only: :test, runtime: false},
      {:credo, "== 1.7.19", only: [:dev, :test], runtime: false},
      {:ex_slop, "== 0.4.5", only: [:dev, :test], runtime: false},
      {:ex_dna, "== 1.5.4", only: [:dev, :test], runtime: false},
      {:credence, "== 0.8.1", only: [:dev, :test], runtime: false},
      {:dialyxir, "== 1.4.8", only: [:dev, :test], runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v0.2.0",
      filter_modules: ~r/^Elixir\.Parlora(?:\.|$)/,
      extras: [
        "README.md",
        "CHANGELOG.md",
        "docs/first-session.md",
        "docs/using-parlora.md",
        "docs/beam-compatibility.md",
        {"examples/order_desk/README.md", filename: "order-desk"},
        {"examples/order_desk/APPLICATION.md", filename: "order-desk-workflows"},
        "docs/browser-channel.md",
        "docs/twilio-channel.md",
        "docs/telnyx-channel.md",
        "docs/openai-provider.md",
        "docs/gemini-provider.md",
        "docs/grok-provider.md",
        "docs/jido-backend.md",
        "docs/sagents-backend.md",
        "docs/legion-backend.md",
        "docs/output-recovery.md",
        "docs/public-interfaces.md",
        "docs/observability.md",
        {"LICENSE", filename: "license", title: "MIT License"}
      ],
      groups_for_extras: [
        "Getting started":
          ~r/(README|first-session|using-parlora|beam-compatibility|APPLICATION)/,
        Channels: ~r/(browser|twilio|telnyx)-channel/,
        Providers: ~r/(openai|gemini|grok)-provider/,
        Backends: ~r/(jido|sagents|legion)-backend/,
        Reference: ~r/(output-recovery|public-interfaces|observability|CHANGELOG|LICENSE)/
      ],
      groups_for_modules: [
        "Session API": [
          Parlora,
          Parlora.Event,
          Parlora.Status,
          Parlora.SessionHealth,
          Parlora.Telemetry
        ],
        Channels: ~r/^Parlora\.Channels\./,
        Providers: ~r/^Parlora\.Providers\./,
        Backends: ~r/^Parlora\.Backends\./,
        "Adapter contracts": [
          Parlora.Channel,
          Parlora.Provider,
          Parlora.Backend,
          Parlora.ContextPolicy
        ]
      ]
    ]
  end

  defp aliases do
    [
      ci: [
        "compile --warnings-as-errors",
        "xref graph --format cycles --label compile-connected --fail-above 0",
        "format --check-formatted",
        "test --raise",
        "parlora.native",
        "credo --strict",
        "ex_dna --max-clones 0",
        "parlora.credence",
        "dialyzer"
      ]
    ]
  end
end
