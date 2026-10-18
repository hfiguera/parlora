defmodule Parlora.Provider.OutputBuffer do
  @moduledoc false
  alias Parlora.{AudioFormat, AudioFrame, AudioQueue, Error}

  def new(limits), do: %AudioQueue{capacity: limits.provider_audio_queue_bytes}

  def burst_limits(format, duration_ms \\ 10_000),
    do: [
      provider_audio_queue_bytes: AudioFormat.bytes_for_ms(format, duration_ms),
      provider_audio_max_age_ms: duration_ms + 1_000
    ]

  def notify(%{waiter: {reader, ref}, inbound: %{bytes: bytes}, output_blocked: false} = state)
      when bytes > 0 do
    send(reader, {:parlora_audio_ready, self(), ref})
    %{state | waiter: nil}
  end

  def notify(state), do: state

  def push(queue, pcm, init, sequence, now) do
    result =
      cond do
        not AudioFormat.aligned?(init.audio_format, pcm) ->
          Error.tuple(:invalid_audio, "Generated audio contains an incomplete sample")

        expired?(queue, init.limits.provider_audio_max_age_ms, now) ->
          Error.tuple(:output_stale, "Generated audio exceeded its receive age limit")

        queue.bytes + byte_size(pcm) > queue.capacity ->
          Error.tuple(:output_overflow, "Generated audio exceeded its receive capacity")

        true ->
          {:ok, enqueue(queue, pcm, init, sequence, now)}
      end

    received(result, queue, pcm, init, now)
    result
  end

  def read(queue, budget, limits, now, init \\ nil) do
    result =
      cond do
        not is_integer(budget) or budget < limits.max_frame_bytes ->
          Error.tuple(:invalid_argument, "Read budget is below the maximum frame size")

        expired?(queue, limits.provider_audio_max_age_ms, now) ->
          Error.tuple(:output_stale, "Generated audio exceeded its receive age limit")

        true ->
          {frames, queue} = AudioQueue.pop(queue, budget)
          {:ok, frames, queue}
      end

    if init do
      case result do
        {:ok, _frames, rest} ->
          :telemetry.execute(
            [:parlora, :provider, :audio_read],
            %{at_us: now, bytes: queue.bytes - rest.bytes, queue_bytes: rest.bytes},
            metadata(init)
          )

        _error ->
          :ok
      end
    end

    result
  end

  defp received(result, before, pcm, init, now) do
    {bytes, dropped, outcome} =
      case result do
        {:ok, {queue, _sequence}} -> {queue.bytes, 0, :accepted}
        {:error, error} -> {before.bytes, byte_size(pcm), error.code}
      end

    :telemetry.execute(
      [:parlora, :provider, :audio_received],
      %{
        at_us: now,
        bytes: byte_size(pcm),
        duration_us: AudioFormat.duration_us(init.audio_format, byte_size(pcm)),
        queue_before_bytes: before.bytes,
        queue_bytes: bytes,
        dropped_bytes: dropped
      },
      Map.put(metadata(init), :outcome, outcome)
    )
  end

  defp metadata(init),
    do: %{session_id: init.session_id, adapter_id: init.adapter_id, generation: init.generation}

  defp expired?(queue, age_ms, now) do
    case :queue.peek(queue.items) do
      {:value, frame} -> now - frame.timestamp_us >= age_ms * 1_000
      :empty -> false
    end
  end

  defp enqueue(queue, <<>>, _init, sequence, _now), do: {queue, sequence}

  defp enqueue(queue, pcm, init, sequence, now) do
    bytes = min(AudioFormat.bytes_for_ms(init.audio_format, 10), byte_size(pcm))
    <<part::binary-size(^bytes), rest::binary>> = pcm

    frame =
      AudioFrame.new(part, init.audio_format, init.adapter_id, sequence,
        generation: init.generation,
        clock: :local_monotonic,
        timestamp_us: now
      )

    {:ok, queue} = AudioQueue.push(queue, frame)
    enqueue(queue, rest, init, sequence + 1, now)
  end
end
