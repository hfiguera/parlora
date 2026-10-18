defmodule ParloraCpalProbe.MixProject do
  use Mix.Project

  def project do
    [
      app: :parlora_cpal_probe,
      version: "0.0.0",
      elixir: "== 1.20.4",
      deps: [{:rustler, "== 0.38.0", runtime: false}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
