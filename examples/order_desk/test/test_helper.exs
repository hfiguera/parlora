# Ordinary regression tests remain deterministic and exercise the default Jido
# path. The Sagents fixture tests explicitly select the optional backend.
Application.put_env(:order_desk, :backend, :jido)

if System.get_env("PARLORA_ACCEPTANCE_REPORT") do
  Code.require_file("../scripts/acceptance_report.exs", __DIR__)
  ExUnit.start(formatters: [ExUnit.CLIFormatter, OrderDesk.AcceptanceReport])
else
  ExUnit.start()
end
