defmodule BookingDesk.MixProject do
  use Mix.Project

  def project do
    [
      app: :booking_desk,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [
        {:parlora, path: "../.."},
        {:jido, "== 2.4.0"},
        {:exqlite, "== 0.40.0"},
        {:typesafe_ai, "== 0.1.0"},
        {:req_llm, "== 1.29.0"},
        {:parlora_observer, path: "../observability", runtime: false}
      ]
    ]
  end

  def application, do: [extra_applications: [:logger], mod: {BookingDesk.Application, []}]
end
