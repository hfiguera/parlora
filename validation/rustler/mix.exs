defmodule ParloraRustlerProbe.MixProject do
  use Mix.Project

  def project do
    [
      app: :parlora_rustler_probe,
      version: "0.0.0",
      elixir: "== 1.20.4",
      test_paths: ["../libopus/test", "test"],
      deps: [{:rustler, "== 0.38.0", runtime: false}, {:ex_webrtc, "== 0.17.0"}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
