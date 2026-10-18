defmodule RecoveryWaitReference do
  @moduledoc false
  alias Parlora.AudioQueue
  alias Parlora.Playout.Target

  # Measured refill target; independent of queue capacity and provider packet boundaries.
  @recovery_target_ms 100

  defstruct buffer_ms: 60,
            recovery_ms: nil,
            recovery_bytes: nil,
            target: nil,
            independent_recovery?: false,
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

  def new(buffer_ms, capacity_bytes, options) do
    mode = Keyword.get(options, :playback_buffering, :fixed)
    ceiling = min(200, div(capacity_bytes, 48))

    recovery =
      if buffer_ms == 0,
        do: 0,
        else: min(Keyword.get(options, :playback_recovery_ms, 120), ceiling)

    state = new(buffer_ms, capacity_bytes)

    %{
      state
      | recovery_ms: recovery,
        independent_recovery?: true,
        target: if(mode == :adaptive and buffer_ms > 0, do: Target.new(buffer_ms, ceiling))
    }
  end

  def valid_options?(buffer, capacity, options) do
    mode = Keyword.get(options, :playback_buffering, :adaptive)
    recovery = Keyword.get(options, :playback_recovery_ms, 120)

    is_integer(buffer) and buffer in 0..200 and buffer * 48 <= capacity and
      mode in [:fixed, :adaptive] and is_integer(recovery) and recovery in 0..200
  end

  def observe(%{target: nil} = state, _frame), do: state

  def observe(state, frame),
    do: %{state | target: Target.observe(state.target, frame, state.recovering?)}

  def reset_timing(state),
    do: %{state | target: if(state.target, do: Target.reset(state.target))}

  def snapshot(state) do
    target = state.target

    %{
      playback_buffering: if(target, do: :adaptive, else: :fixed),
      playback_buffer_ms: state.buffer_ms,
      playback_target_ms: if(target, do: target.target_ms, else: state.buffer_ms),
      playback_min_target_ms: if(target, do: target.floor_ms, else: state.buffer_ms),
      playback_max_target_ms: if(target, do: target.ceiling_ms, else: state.buffer_ms),
      recovery_buffer_ms: div(recovery_wait_us(state), 1_000),
      playback_target_increases: if(target, do: target.increases, else: 0),
      playback_target_decreases: if(target, do: target.decreases, else: 0),
      playback_idle_resets: if(target, do: target.idle_resets, else: 0),
      playback_clock_resets: if(target, do: target.clock_resets, else: 0)
    }
  end

  def reset(state),
    do: %{
      state
      | playing?: false,
        waiting_since_us: nil,
        empty_since_us: nil,
        recovering?: false,
        release_reason: nil,
        target: if(state.target, do: Target.reset(state.target))
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
    state = boundary(state, now)
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

  # Recovery has an independent time cap. A learned increase rebuilds the
  # adaptive cushion, without stretching samples or growing queues.
  # The two-argument constructor retains the historical fixed policy for replay.
  # A ready cushion releases immediately within the configured cap.
  # Severe stalls retain a bounded settling interval; the deadline still drains
  # short tails. Initial buffering and explicit pressure release are independent.
  def recovery_wait_us(state),
    do:
      if(state.independent_recovery?,
        do: state.recovery_ms,
        else: min(state.recovery_ms || state.buffer_ms, state.buffer_ms)
      ) * 1_000

  # A long idle interval returns through startup rather than recovery. Report
  # its actual startup deadline instead of the separately configured recovery cap.
  def wait_limit_us(state, now) do
    state = boundary(state, now)
    if state.recovering?, do: recovery_wait_us(state), else: state.buffer_ms * 1_000
  end

  defp boundary(%{target: target, playing?: false, waiting_since_us: nil} = state, now)
       when target != nil do
    idle? = state.empty_since_us != nil and now - state.empty_since_us >= 1_000_000
    %{state | buffer_ms: target.target_ms, recovering?: state.recovering? and not idle?}
  end

  defp boundary(state, _now), do: state

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
    cushion = if state.target, do: state.buffer_ms * 48, else: state.recovery_bytes * 2

    # Learning a larger target is useful only if recovery actually rebuilds it.
    # Restarting with one provider chunk can otherwise leave no timing margin
    # and turn small subsequent arrival delays into repeated interruptions.
    target =
      if state.target && state.buffer_ms > state.target.floor_ms,
        do: cushion,
        else: min(cushion, div((shortage_us(state) + 20_000) * 48, 1_000))

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
