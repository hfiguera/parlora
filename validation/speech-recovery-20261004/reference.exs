defmodule SpeechRecoveryReference do
  @moduledoc false
  alias Parlora.AudioQueue
  alias Parlora.Playout.{QuietRefill, Target}

  # Measured refill target; independent of queue capacity and provider packet boundaries.
  @recovery_target_ms 100

  defstruct buffer_ms: 60,
            recovery_ms: nil,
            recovery_bytes: nil,
            target: nil,
            quiet: nil,
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
        target: if(mode == :adaptive and buffer_ms > 0, do: Target.new(buffer_ms, ceiling)),
        quiet: if(mode == :adaptive and buffer_ms > 0, do: %QuietRefill{})
    }
  end

  def valid_options?(buffer, capacity, options) do
    mode = Keyword.get(options, :playback_buffering, :adaptive)
    recovery = Keyword.get(options, :playback_recovery_ms, 120)

    is_integer(buffer) and buffer in 0..200 and buffer * 48 <= capacity and
      mode in [:fixed, :adaptive] and is_integer(recovery) and recovery in 0..200
  end

  def observe(%{target: nil} = state, _frame), do: state

  def observe(state, frame) do
    group = state.target.group

    state = if timing_reset?(group, frame), do: reset_timing(state), else: state

    state =
      if idle_receipt?(group, frame),
        do: %{state | quiet: QuietRefill.reset(state.quiet)},
        else: state

    %{
      state
      | target:
          Target.observe(
            state.target,
            frame,
            state.recovering? and not QuietRefill.active?(state.quiet)
          )
    }
  end

  defp timing_reset?(group, frame) do
    frame.discontinuity or frame.clock != :local_monotonic or
      not is_integer(frame.timestamp_us) or
      (group != nil and
         (group.identity != {frame.stream_id, frame.generation} or frame.timestamp_us < group.at))
  end

  defp idle_receipt?(group, frame),
    do:
      group != nil and is_integer(frame.timestamp_us) and
        frame.timestamp_us - group.at - group.duration >= 1_000_000

  def reset_timing(state) do
    state = if QuietRefill.active?(state.quiet), do: release_recovery(state), else: state

    %{
      state
      | target: if(state.target, do: Target.reset(state.target)),
        quiet: QuietRefill.reset(state.quiet)
    }
  end

  def snapshot(state) do
    target = state.target

    %{
      playback_buffering: if(target, do: :adaptive, else: :fixed),
      playback_buffer_ms: state.buffer_ms,
      playback_target_ms: if(target, do: target.target_ms, else: state.buffer_ms),
      playback_min_target_ms: if(target, do: target.floor_ms, else: state.buffer_ms),
      playback_max_target_ms: if(target, do: target.ceiling_ms, else: state.buffer_ms),
      recovery_buffer_ms: div(recovery_wait_us(state), 1_000),
      quiet_refills: quiet_refills(state),
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
        target: if(state.target, do: Target.reset(state.target)),
        quiet: QuietRefill.reset(state.quiet)
    }

  def release_recovery(%{recovering?: true} = state),
    do: %{
      state
      | playing?: true,
        recovering?: false,
        quiet: QuietRefill.finish(state.quiet),
        release_reason: :pressure
    }

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
          quiet: QuietRefill.empty(state.quiet, state.playing?),
          recovering?: state.recovering? or state.playing?,
          empty_since_us: state.empty_since_us || now
      },
      queue
    )
  end

  def take(state, queue, budget, now) do
    state = quiet_refill(state, queue, now)
    state = boundary(state, now)
    since = state.waiting_since_us || now
    state = %{state | waiting_since_us: since}

    if not state.playing? and buffering?(state, queue, now - since) do
      silence(%{state | waiting_since_us: since}, queue)
    else
      reason = release_reason(state, queue)
      {frames, queue} = AudioQueue.pop(queue, budget)
      pcm = Enum.map_join(frames, & &1.data)
      quiet = QuietRefill.observe(state.quiet, pcm, state.source_bytes + byte_size(pcm))

      {pcm, queue,
       %{
         state
         | playing?: true,
           recovering?: false,
           release_reason: reason,
           waiting_since_us: nil,
           empty_since_us: nil,
           source_bytes: state.source_bytes + byte_size(pcm),
           quiet: QuietRefill.finish(quiet)
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

  def quiet_refills(%{quiet: nil}), do: 0
  def quiet_refills(state), do: state.quiet.count

  def quiet_refill?(state), do: QuietRefill.active?(state.quiet)

  # A long idle interval returns through startup rather than recovery. Report
  # its actual startup deadline instead of the separately configured recovery cap.
  def wait_limit_us(state, now) do
    state = boundary(state, now)

    cond do
      QuietRefill.active?(state.quiet) -> min(recovery_wait_us(state), QuietRefill.wait_us())
      state.recovering? -> recovery_wait_us(state)
      true -> state.buffer_ms * 1_000
    end
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
      QuietRefill.active?(state.quiet) -> :quiet_refill
      speech_resume?(state, queue) -> :speech_continuation
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

    if QuietRefill.active?(state.quiet),
      do: queue.bytes < state.buffer_ms * 48 and waited < min(cap, QuietRefill.wait_us()),
      else: (not cushion_ready?(state, queue) or waited < minimum) and waited < maximum
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

    speech_resume?(state, queue) or queue.bytes >= min(queue.capacity, target)
  end

  defp speech_resume?(state, queue),
    do:
      QuietRefill.resume?(
        state.quiet,
        state.target,
        queue,
        state.source_bytes,
        shortage_us(state),
        recovery_wait_us(state)
      )

  defp quiet_refill(%{playing?: true, target: target} = state, queue, now) when target != nil do
    if recovery_wait_us(state) > 0 and QuietRefill.start?(state.quiet, target, queue) do
      %{
        state
        | buffer_ms: target.target_ms,
          playing?: false,
          recovering?: true,
          waiting_since_us: now,
          empty_since_us: now,
          quiet: QuietRefill.start(state.quiet)
      }
    else
      state
    end
  end

  defp quiet_refill(state, _queue, _now), do: state

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
