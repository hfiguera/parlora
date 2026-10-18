defmodule Parlora.Pacer do
  @moduledoc false

  def next(previous_deadline, duration_us),
    do: next(previous_deadline, duration_us, System.monotonic_time(:microsecond))

  def next(previous_deadline, duration_us, now) do
    deadline = max(previous_deadline + duration_us, now)
    {deadline, max(1, div(deadline - now + 999, 1_000))}
  end
end
