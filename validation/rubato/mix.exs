defmodule ParloraRubatoProbe.MixProject do
  use Mix.Project

  def project do
    [
      app: :parlora_rubato_probe,
      version: "0.0.0",
      elixir: "== 1.20.4",
      deps: [{:rustler, "== 0.38.0", runtime: false}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
