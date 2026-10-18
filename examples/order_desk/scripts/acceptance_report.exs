defmodule OrderDesk.AcceptanceReport do
  use GenServer
  def init(_), do: {:ok, []}

  def handle_cast({:test_finished, test}, state) do
    result = %{
      name: test.name,
      status: if(test.state == nil, do: "passed", else: "failed"),
      duration_ms: div(test.time, 1000),
      failure: if(test.state, do: inspect(test.state, limit: 30), else: nil)
    }

    {:noreply, [result | state]}
  end

  def handle_cast({:suite_finished, _}, state) do
    if path = System.get_env("PARLORA_ACCEPTANCE_REPORT") do
      File.write!(
        path,
        Jason.encode!(%{mode: "deterministic", cases: Enum.reverse(state)}, pretty: true)
      )
    end

    {:noreply, state}
  end

  def handle_cast(_, state), do: {:noreply, state}
end
