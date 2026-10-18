unless Code.ensure_loaded?(Parlora.TestSupport.RecordedPlayout),
  do: Code.require_file("recorded_playout.exs", __DIR__)

alias Parlora.TestSupport.RecordedPlayout

defmodule ImmediatePlayout do
  defdelegate new(ms, capacity), to: RecordedPlayout
  defdelegate release_recovery(state), to: RecordedPlayout

  def take(%{recovering?: true} = state, %{bytes: bytes} = queue, budget, now) when bytes > 0 do
    RecordedPlayout.take(
      %{state | playing?: true, recovering?: false, release_reason: :source_ready},
      queue,
      budget,
      now
    )
  end

  defdelegate take(state, queue, budget, now), to: RecordedPlayout
end

defmodule FixedStartPlayout do
  defdelegate new(ms, capacity), to: RecordedPlayout
  defdelegate release_recovery(state), to: RecordedPlayout

  def take(%{playing?: false, recovering?: false} = state, %{bytes: bytes} = queue, budget, now)
      when bytes > 0 do
    since = state.waiting_since_us || now

    if now - since < state.buffer_ms * 1_000 do
      {:binary.copy(<<0>>, 480), queue,
       %{state | waiting_since_us: since, silence_bytes: state.silence_bytes + 480}}
    else
      ImmediatePlayout.take(%{state | playing?: true}, queue, budget, now)
    end
  end

  defdelegate take(state, queue, budget, now), to: ImmediatePlayout
end

defmodule BoundedRefillPlayout do
  def take(%{recovering?: true} = state, %{bytes: bytes} = queue, budget, now) when bytes > 0 do
    since = state.waiting_since_us || now

    if bytes >= state.recovery_bytes or now - since >= state.recovery_ms * 1_000 do
      reason = if bytes >= state.recovery_bytes, do: :queue_ready, else: :deadline

      RecordedPlayout.take(
        %{state | playing?: true, recovering?: false, release_reason: reason},
        queue,
        budget,
        now
      )
    else
      {:binary.copy(<<0>>, 480), queue,
       %{state | waiting_since_us: since, silence_bytes: state.silence_bytes + 480}}
    end
  end

  defdelegate take(state, queue, budget, now), to: RecordedPlayout
end

for {name, target, wait} <- [
      {Refill40Playout, 40, 20},
      {Refill60Playout, 60, 20},
      {Refill100Playout, 100, 20},
      {Refill100Wait40Playout, 100, 40},
      {Refill120Wait60Playout, 120, 60},
      {Refill120Wait120Playout, 120, 120},
      {Refill100Wait120Playout, 100, 120},
      {Refill140Wait120Playout, 140, 120}
    ] do
  Module.create(
    name,
    quote do
      def new(ms, capacity) do
        state = Parlora.TestSupport.RecordedPlayout.new(ms, capacity)

        %{
          state
          | recovery_bytes: min(unquote(target) * 48, capacity),
            recovery_ms: min(ms, unquote(wait))
        }
      end

      defdelegate release_recovery(state), to: Parlora.TestSupport.RecordedPlayout
      defdelegate take(state, queue, budget, now), to: BoundedRefillPlayout
    end,
    Macro.Env.location(__ENV__)
  )
end
