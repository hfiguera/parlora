defmodule BookingDesk.MixProject do
  use Mix.Project

  def project do
    [
      app: :booking_desk,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      dialyzer: [
        plt_add_apps: [:mix, :credence] ++ if(Mix.env() == :test, do: [:ex_unit], else: [])
      ],
      deps: [
        {:parlora, path: "../.."},
        {:jido, "== 2.4.0"},
        {:exqlite, "== 0.40.0"},
        {:typesafe_ai, "== 0.1.0"},
        {:req_llm, "== 1.29.0"},
        {:parlora_observer, path: "../observability", runtime: false},
        {:credo, "== 1.7.19", only: [:dev, :test], runtime: false},
        {:ex_dna, "== 1.5.4", only: [:dev, :test], runtime: false},
        {:credence, "== 0.8.1", only: [:dev, :test], runtime: false},
        {:dialyxir, "== 1.4.8", only: [:dev, :test], runtime: false}
      ]
    ]
  end

  def cli, do: [preferred_envs: [ci: :test]]

  def application, do: [extra_applications: [:logger], mod: {BookingDesk.Application, []}]

  defp elixirc_paths(env) when env in [:dev, :test], do: ["lib", "dev"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      ci: [
        "compile --warnings-as-errors",
        "xref graph --format cycles --label compile-connected --fail-above 0",
        "format --check-formatted",
        "test --warnings-as-errors --raise",
        "credo --config-file .credo.exs --strict",
        "ex_dna --max-clones 0",
        "booking_desk.credence",
        "dialyzer"
      ]
    ]
  end
end
