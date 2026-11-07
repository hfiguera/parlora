defmodule Parlora.Playout.LeadIn do
  @moduledoc false
  alias Parlora.AudioQueue

  # Probe only audio the startup buffer already has. Silence the short
  # isolated burst in place so the playback clock and frame positions agree.
  @burst_bytes 3_840
  @quiet_bytes 1_920

  def render(nil, _queue, pcm), do: {pcm, nil}
  def render(0, _queue, pcm), do: {pcm, 0}
  def render(:armed, queue, pcm), do: render(prefix_to_mute(queue), queue, pcm)

  def render(remaining, _queue, pcm) do
    size = min(remaining, byte_size(pcm))
    <<_prefix::binary-size(^size), tail::binary>> = pcm
    {:binary.copy(<<0>>, size) <> tail, remaining - size}
  end

  defp prefix_to_mute(%{bytes: bytes} = queue) when bytes >= @burst_bytes + @quiet_bytes do
    {pcm, _} = AudioQueue.take_bytes(queue, @burst_bytes + @quiet_bytes)
    <<burst::binary-size(2_880), decay::binary-size(960), quiet::binary>> = pcm

    if peak(burst) >= 1_024 and peak(decay) < 512 and peak(quiet) < 256,
      do: @burst_bytes,
      else: 0
  end

  defp prefix_to_mute(_queue), do: 0

  defp peak(pcm) do
    for <<sample::little-signed-16 <- pcm>>, reduce: 0 do
      peak -> max(peak, abs(sample))
    end
  end
end
