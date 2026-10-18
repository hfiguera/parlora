defmodule Parlora.TestSupport.AudioBenchmark.Gaps do
  @moduledoc false
  defstruct current: nil, completed: []

  def observe(%{current: current} = state, true, _available, _gap, now)
      when current != nil do
    returned = current.returned || now

    gap = %{
      duration_us: now - current.start,
      source_unavailable_us: returned - current.start,
      recovery_wait_us: now - returned
    }

    %{state | current: nil, completed: [gap | state.completed]}
  end

  def observe(state, false, available, true, now) do
    current = state.current || %{start: now, returned: nil}
    returned = current.returned || if(available, do: now)
    %{state | current: %{current | returned: returned}}
  end

  def observe(state, _source, _available, _gap, _now), do: state

  # The repeated-shortage fixture supplies 100 ms packets. For an ordinary
  # shortage <=80 ms, forwarding that packet takes <=20 ms plus one output tick.
  def ordinary_wait_bounded?(state) do
    Enum.all?(state.completed, fn gap ->
      gap.source_unavailable_us > 80_000 or gap.recovery_wait_us <= 30_000
    end)
  end
end
