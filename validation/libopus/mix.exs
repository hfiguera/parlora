defmodule ParloraOpusProbe.MixProject do
  use Mix.Project

  def project do
    [
      app: :parlora_opus_probe,
      version: "0.0.0",
      elixir: "== 1.20.4",
      compilers: [:elixir_make] ++ Mix.compilers(),
      deps: [{:elixir_make, "== 0.10.0", runtime: false}, {:ex_webrtc, "== 0.17.0"}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
