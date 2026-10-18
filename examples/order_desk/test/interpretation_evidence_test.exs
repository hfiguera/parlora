defmodule OrderDesk.InterpretationEvidenceTest do
  use ExUnit.Case, async: true

  test "private evidence is bounded and excluded from dashboard statistics" do
    {:ok, pid} = GenServer.start_link(OrderDesk.Interpretation, [])
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    for revision <- 1..140 do
      GenServer.cast(
        pid,
        {:trace, %{kind: "judgment", context_revision: revision, input: %{text: "test"}}}
      )
    end

    evidence = GenServer.call(pid, :evidence)
    assert length(evidence) == 128
    assert hd(evidence).context_revision == 13
    assert List.last(evidence).context_revision == 140
    refute Map.has_key?(GenServer.call(pid, :stats), :evidence)
    GenServer.cast(pid, {:trace, %{kind: "judgment", input: String.duplicate("x", 33_000)}})
    assert List.last(GenServer.call(pid, :evidence)).omitted == "size_limit"
  end
end
