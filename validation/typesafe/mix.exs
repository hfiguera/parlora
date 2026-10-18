defmodule ParloraTypeSafeEval.MixProject do
  use Mix.Project

  def project do
    [
      app: :parlora_typesafe_eval,
      version: "0.1.0",
      elixir: "== 1.20.4",
      deps: [{:typesafe_ai, "== 0.1.0"}]
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]
end
