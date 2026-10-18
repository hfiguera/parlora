defmodule Parlora.TestSupport.RecordedPlayout do
  @moduledoc false
  alias Parlora.AudioQueue

  # Measured refill target; independent of queue capacity and provider packet boundaries.
  @recovery_target_ms 100

  defstruct buffer_ms: 60,
            recovery_ms: nil,
            recovery_bytes: nil,
            recovering?: false,
            playing?: false,
            waiting_since_us: nil,
            empty_since_us: nil,
            release_reason: nil,
            starvations: 0,
            source_bytes: 0,
            silence_bytes: 0

  def new(buffer_ms, capacity_bytes) do
    recovery = if buffer_ms == 0, do: 0, else: min(200, div(capacity_bytes, 48))
    target_bytes = min(min(recovery, buffer_ms), @recovery_target_ms) * 48
    %__MODULE__{buffer_ms: buffer_ms, recovery_ms: recovery, recovery_bytes: target_bytes}
  end

  def reset(state),
    do: %{
      state
      | playing?: false,
        waiting_since_us: nil,
        empty_since_us: nil,
        recovering?: false,
        release_reason: nil
    }

  def release_recovery(%{recovering?: true} = state),
    do: %{state | playing?: true, recovering?: false, release_reason: :pressure}

  def release_recovery(state), do: state

  def take(state, %{bytes: 0} = queue, _budget, now) do
    starvations = state.starvations + if(state.playing?, do: 1, else: 0)

    silence(
      %{
        state
        | playing?: false,
          waiting_since_us: nil,
          release_reason: nil,
          starvations: starvations,
          recovering?: state.recovering? or state.playing?,
          empty_since_us: state.empty_since_us || now
      },
      queue
    )
  end

  def take(state, queue, budget, now) do
    since = state.waiting_since_us || now
    state = %{state | waiting_since_us: since}

    if not state.playing? and buffering?(state, queue, now - since) do
      silence(%{state | waiting_since_us: since}, queue)
    else
      reason = release_reason(state, queue)
      {frames, queue} = AudioQueue.pop(queue, budget)
      pcm = Enum.map_join(frames, & &1.data)

      {pcm, queue,
       %{
         state
         | playing?: true,
           recovering?: false,
           release_reason: reason,
           waiting_since_us: nil,
           empty_since_us: nil,
           source_bytes: state.source_bytes + byte_size(pcm)
       }}
    end
  end

  # Upper bound retained for diagnostics and legacy controls. Actual recovery
  # uses only the current shortage, so earlier recoveries cannot extend later
  # speech gaps. A ready cushion releases immediately within the configured cap.
  # Severe stalls retain a bounded settling interval; the deadline still drains
  # short tails. Initial buffering and explicit pressure release are independent.
  def recovery_wait_us(state),
    do: min(state.recovery_ms || state.buffer_ms, state.buffer_ms) * 1_000

  defp release_reason(%{recovering?: true} = state, queue) do
    cond do
      recovery_wait_us(state) == 0 -> :buffering_disabled
      state.recovery_ms == nil or cushion_ready?(state, queue) -> :queue_ready
      true -> :deadline
    end
  end

  defp release_reason(state, _bytes), do: state.release_reason

  defp buffering?(%{recovering?: true, recovery_bytes: bytes} = state, queue, waited)
       when is_integer(bytes) do
    shortage = shortage_us(state)
    cap = recovery_wait_us(state)
    # Only the portion beyond the configured cushion needs settling. This
    # preserves headroom after severe stalls without a half-shortage penalty
    # for ordinary jitter; the transition is continuous at the cap.
    minimum = min(max(0, shortage - cap), div(cap, 2))
    maximum = min(shortage + 20_000, cap)
    (not cushion_ready?(state, queue) or waited < minimum) and waited < maximum
  end

  defp buffering?(%{recovering?: true, recovery_ms: ms} = state, _queue, waited)
       when is_integer(ms), do: waited < recovery_wait_us(state)

  defp buffering?(state, queue, waited),
    do: queue.bytes < state.buffer_ms * 48 and waited < state.buffer_ms * 1_000

  defp cushion_ready?(%{recovery_bytes: nil}, _queue), do: false

  defp cushion_ready?(state, queue) do
    target = min(state.recovery_bytes * 2, div((shortage_us(state) + 20_000) * 48, 1_000))
    queue.bytes >= min(queue.capacity, target)
  end

  defp shortage_us(state),
    do:
      max(
        0,
        (state.waiting_since_us || 0) - (state.empty_since_us || state.waiting_since_us || 0)
      )

  defp silence(state, queue) do
    {:binary.copy(<<0, 0>>, 240), queue, %{state | silence_bytes: state.silence_bytes + 480}}
  end
end
