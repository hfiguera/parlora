defmodule Parlora.Channels.Browser.PlaybackDiagnostics do
  @moduledoc false

  # Constant space: one open interval, one completed summary, no retained PCM.
  defstruct count: 0, last_peak: nil, gap: nil, last_gap: nil

  def source_available(%{gap: %{source_returned_at_us: nil} = gap} = state, now, bytes, wait) do
    %{
      state
      | gap: %{
          gap
          | source_returned_at_us: now,
            source_return_queue_bytes: bytes,
            recovery_target_us: wait
        }
    }
  end

  def source_available(state, _now, _bytes, _wait), do: state

  def released(%{gap: nil} = state, _reason, _bytes), do: state

  def released(state, reason, bytes),
    do: %{state | gap: %{state.gap | recovery_release_reason: reason, resume_queue_bytes: bytes}}

  def observe(state, pcm, source?, now, epoch, cause \\ :source_queue_empty)

  def observe(state, pcm, true, now, epoch, _cause) do
    peak = peak(pcm)
    {state, event} = finish(state, :source_resumed, now, peak)
    {%{state | last_peak: peak}, event && Map.put(event, :epoch, epoch)}
  end

  def observe(%{last_peak: nil} = state, _pcm, false, _now, _epoch, _cause), do: {state, nil}

  def observe(%{gap: nil} = state, pcm, false, now, epoch, cause) do
    gap = %{
      gap_id: state.count + 1,
      epoch: epoch,
      start_cause: cause,
      started_at_us: now,
      peak_before: state.last_peak,
      silence_bytes: byte_size(pcm),
      source_returned_at_us: nil,
      source_return_queue_bytes: nil,
      recovery_target_us: nil,
      recovery_release_reason: nil,
      resume_queue_bytes: nil
    }

    next = %{state | gap: gap, count: gap.gap_id}
    {next, summary(gap, cause, now, nil)}
  end

  def observe(state, pcm, false, _now, _epoch, _cause) do
    gap = %{state.gap | silence_bytes: state.gap.silence_bytes + byte_size(pcm)}
    {%{state | gap: gap}, nil}
  end

  def finish(state, reason, now, peak_after \\ nil)
  def finish(%{gap: nil} = state, _reason, _now, _peak), do: {state, nil}

  def finish(state, reason, now, peak) do
    event = summary(state.gap, reason, now, peak)
    {%{state | gap: nil, last_peak: nil, last_gap: event}, event}
  end

  def reset(state), do: %{state | gap: nil, last_peak: nil}

  def snapshot(state, now) do
    %{
      source_queue_empty_count: state.count,
      open_gap: state.gap && summary(state.gap, state.gap.start_cause, now, nil),
      last_gap: state.last_gap
    }
  end

  defp summary(gap, cause, now, peak_after) do
    Map.merge(Map.delete(gap, :start_cause), %{
      cause: cause,
      boundary: :browser_pcm,
      duration_us: max(0, now - gap.started_at_us),
      inserted_silence_us: div(gap.silence_bytes * 1_000_000, 48_000),
      source_unavailable_us: max(0, (gap.source_returned_at_us || now) - gap.started_at_us),
      recovery_wait_us:
        if(gap.source_returned_at_us, do: max(0, now - gap.source_returned_at_us), else: 0),
      recovery_release_reason:
        if(cause in [:cleared, :closed], do: cause, else: gap.recovery_release_reason),
      peak_after: peak_after
    })
  end

  defp peak(pcm) do
    for <<sample::little-signed-16 <- pcm>>, reduce: 0 do
      maximum -> max(maximum, abs(sample))
    end
  end
end
