defmodule Parlora.AudioObserver do
  @moduledoc false
  @capacity 256
  # Only credit accounting and a bounded send run on the audio process. The
  # receiver decrements slot 1 after processing; slot 2 counts dropped packets.
  def send_audio(%{pid: pid, credits: credits}, direction, pcm)
      when is_pid(pid) and byte_size(pcm) > 0 do
    if :atomics.add_get(credits, 1, 1) <= @capacity do
      send(pid, {:parlora_audio, direction, System.monotonic_time(:microsecond), pcm})
    else
      :atomics.sub(credits, 1, 1)
      :atomics.add(credits, 2, 1)
    end

    :ok
  end

  def send_audio(_observer, _direction, _pcm), do: :ok
end
