defmodule OptionalBackendConsumer.MixProject do
  use Mix.Project

  def project do
    [
      app: :optional_backend_consumer,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
      deps: [{:parlora, path: "vendor/parlora"}] ++ framework()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp framework do
    case System.get_env("PARLORA_OPTIONAL_BACKEND", "none") do
      "none" -> []
      "jido" -> [{:jido, "== 2.4.0"}]
      "sagents" -> [{:sagents, "== 0.19.2"}]
      "legion" -> [{:legion, "== 0.6.0"}]
    end
  end
end
