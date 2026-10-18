defmodule OrderDesk.InterpretationTimingTest do
  use ExUnit.Case, async: false

  defmodule TimedClient do
    use GenServer
    def start_link(_), do: GenServer.start_link(__MODULE__, [], name: OrderDesk.TypeSafe)
    def init(_), do: {:ok, nil}

    def handle_call({:evaluate, _request}, _from, state) do
      Process.sleep(15)
      {:reply, {:error, TypeSafe.Error.new(:timeout, "Fixture deadline")}, state}
    end
  end

  test "timeout evidence separates coalescing from evaluation without changing the decision" do
    start_supervised!(TimedClient)
    input = %{active_task: nil, recent_work: [], order_candidates: ["124"]}

    assert {:error, :timeout} =
             OrderDesk.Interpretation.classify(input,
               fresh?: true,
               session_id: "timing-fixture"
             )

    record =
      OrderDesk.Interpretation.evidence()
      |> Enum.find(&(&1[:session_id] == "timing-fixture"))

    assert record.result == "{:error, :timeout}"
    assert record.timing_ms.coalesce >= 200
    assert record.timing_ms.evaluation >= 15
    assert record.timing_ms.total == record.timing_ms.coalesce + record.timing_ms.evaluation
    refute Map.has_key?(OrderDesk.Interpretation.stats(), :timing_ms)
  end
end
