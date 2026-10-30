defmodule OrderDesk.MixProject do
  use Mix.Project

  def project do
    [
      app: :order_desk,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps:
        [
          {:typesafe_ai, "== 0.1.0"},
          {:exqlite, "== 0.40.0"},
          {:parlora, path: "vendor/parlora"},
          {:jido, "== 2.4.0"},
          {:bandit, "== 1.14.1"},
          {:plug, "== 1.20.3"}
        ] ++
          case System.get_env("PARLORA_BACKEND") do
            "sagents" -> [{:sagents, "== 0.19.2"}]
            "legion" -> [{:legion, "== 0.6.0"}]
            _default -> []
          end
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {OrderDesk.Application, []}]
  end
end
