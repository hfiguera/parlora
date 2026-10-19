defmodule ParloraObserver.MixProject do
  use Mix.Project

  def project do
    [app: :parlora_observer, version: "0.1.0", elixir: "~> 1.18", deps: deps()]
  end

  def application do
    [
      extra_applications: [:logger, :opentelemetry_exporter, :opentelemetry],
      mod: {ParloraObserver.Application, []}
    ]
  end

  defp deps do
    [
      {:parlora, path: "../.."},
      {:opentelemetry_api, "~> 1.5"},
      {:opentelemetry, "~> 1.7"},
      {:opentelemetry_exporter, "~> 1.11"},
      {:telemetry_metrics, "~> 1.2"},
      {:telemetry_metrics_prometheus_core, "~> 1.2"}
    ]
  end
end
