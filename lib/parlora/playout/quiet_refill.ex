defmodule Parlora.Playout.QuietRefill do
  @moduledoc false
  alias Parlora.AudioQueue

  # A conservative amplitude gate, not a speech recognizer. All samples must
  # be below approximately -54 dBFS before moving a refill into that passage.
  @quiet_peak 64
  @quiet_us 20_000
  @wait_us 60_000

  defstruct quiet_us: 0,
            seen_nonquiet?: false,
            refilled?: false,
            refilling?: false,
            last_quiet_byte: nil,
            count: 0

  def wait_us, do: @wait_us
  def active?(state), do: state != nil and state.refilling?
  def reset(nil), do: nil
  def reset(state), do: %__MODULE__{count: state.count}

  def empty(nil, _playing), do: nil
  def empty(state, true), do: %{state | refilled?: false}
  def empty(state, false), do: state

  def start?(state, target, queue), do: start?(state, target, queue, false)

  def start?(%{seen_nonquiet?: true, refilled?: false, quiet_us: quiet}, target, queue, borrowed?)
      when quiet >= @quiet_us do
    threshold = if borrowed?, do: target.target_ms * 48, else: div(target.target_ms * 48, 2)

    target.group != nil and target.target_ms > target.floor_ms and
      queue.bytes < threshold and
      quiet_head?(queue)
  end

  def start?(_state, _target, _queue, _borrowed), do: false
  def start(state), do: %{state | refilling?: true, refilled?: true, count: state.count + 1}
  def finish(nil), do: nil
  def finish(state), do: %{state | refilling?: false}

  def observe(nil, _pcm, _position), do: nil

  def observe(state, pcm, position) do
    if quiet?(pcm) do
      quiet = min(200_000, state.quiet_us + div(byte_size(pcm) * 1_000_000, 48_000))

      %{
        state
        | quiet_us: quiet,
          last_quiet_byte: if(quiet >= @quiet_us, do: position, else: state.last_quiet_byte)
      }
    else
      %{state | quiet_us: 0, seen_nonquiet?: true, refilled?: false}
    end
  end

  # At an onset after a quiet passage, a brief shortage need not stop available
  # speech until the entire learned target is rebuilt. Require at least one
  # locally measured receipt group's duration, with an 80 ms minimum. This is
  # bounded evidence for a restart, not a guarantee about the next arrival.
  def resume?(
        %{quiet_us: 0, last_quiet_byte: at},
        %{group: %{duration: duration}},
        queue,
        position,
        shortage,
        cap
      )
      when at != nil do
    position - at <= 9_600 and shortage <= div(cap, 3) and
      queue.bytes >= div(max(80_000, duration) * 48, 1_000) and not quiet_head?(queue)
  end

  def resume?(_state, _target, _queue, _position, _shortage, _cap), do: false

  # During established speech, a whole substantial receipt can bridge ordinary
  # jitter without waiting for a second receipt to rebuild the learned target.
  # Small fragments, quiet tails and unknown receipt timing keep normal recovery.
  def continuation_ready?(
        %{seen_nonquiet?: true, quiet_us: 0, last_quiet_byte: last_quiet},
        %{group: %{duration: duration}},
        queue,
        position
      )
      when duration >= 80_000 and duration <= 200_000 and last_quiet != nil do
    position - last_quiet > 9_600 and position - last_quiet <= 48_000 and
      queue.bytes >= div(duration * 48, 1_000) and
      not quiet_head?(queue)
  end

  def continuation_ready?(_state, _target, _queue, _position), do: false

  defp quiet_head?(queue) do
    {pcm, _rest} = AudioQueue.take_bytes(queue, 480)
    byte_size(pcm) == 480 and quiet?(pcm)
  end

  defp quiet?(<<>>), do: true

  defp quiet?(<<sample::little-signed-16, rest::binary>>),
    do: abs(sample) <= @quiet_peak and quiet?(rest)
end
