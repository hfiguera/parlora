defmodule Parlora.Channels.LocalAudio.PlaybackProgress do
  @moduledoc false

  defstruct source_bytes: 0,
            converted_bytes: 0,
            native_frames: 0,
            delay_frames: 0,
            source_starts: :queue.new(),
            native_starts: :queue.new(),
            last_handed_off_sequence: nil

  def new(handed_off, delay_frames) do
    %__MODULE__{native_frames: handed_off, delay_frames: delay_frames}
  end

  def append(progress, frames, input_bytes, pending_bytes, output_frames) do
    {source_starts, _offset} =
      Enum.reduce(frames, {progress.source_starts, progress.source_bytes}, fn frame,
                                                                              {starts, offset} ->
        {:queue.in({offset, frame.sequence}, starts), offset + byte_size(frame.data)}
      end)

    source_bytes = progress.source_bytes + input_bytes
    converted_bytes = source_bytes - pending_bytes
    converted_now = converted_bytes - progress.converted_bytes

    {pending, native_starts} =
      locate_starts(source_starts, progress.native_starts, progress, converted_now, output_frames)

    %{
      progress
      | source_bytes: source_bytes,
        converted_bytes: converted_bytes,
        native_frames: progress.native_frames + output_frames,
        source_starts: pending,
        native_starts: native_starts
    }
  end

  def observe(progress, handed_off) do
    case :queue.out(progress.native_starts) do
      {{:value, {start, sequence}}, remaining} when start < handed_off ->
        observe(
          %{progress | native_starts: remaining, last_handed_off_sequence: sequence},
          handed_off
        )

      _ ->
        progress
    end
  end

  def clear(progress, handed_off) do
    observed = observe(progress, handed_off)

    %{
      new(handed_off, progress.delay_frames)
      | last_handed_off_sequence: observed.last_handed_off_sequence
    }
  end

  defp locate_starts(source, native, progress, converted_now, output_frames) do
    case :queue.out(source) do
      {{:value, {offset, sequence}}, remaining}
      when offset < progress.converted_bytes + converted_now ->
        # Resampling preserves order but shifts the first output sample by the filter delay.
        start =
          progress.native_frames + progress.delay_frames +
            div((offset - progress.converted_bytes) * output_frames, converted_now)

        locate_starts(
          remaining,
          :queue.in({start, sequence}, native),
          progress,
          converted_now,
          output_frames
        )

      _ ->
        {source, native}
    end
  end
end
