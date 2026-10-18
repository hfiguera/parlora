defmodule Parlora.AudioClock do
  @moduledoc false
  defstruct [:at_us, :captured, :rendered, input_ppm: 0, output_ppm: 0]

  def sample(%__MODULE__{at_us: nil} = clock, stats, now),
    do: {nil, %{clock | at_us: now, captured: stats.captured, rendered: stats.rendered}}

  def sample(clock, stats, now) when now - clock.at_us >= 5_000_000 do
    elapsed = now - clock.at_us
    input = estimate(stats.captured - clock.captured, stats.input_rate, elapsed)
    output = estimate(stats.rendered - clock.rendered, stats.output_rate, elapsed)

    next = %{
      clock
      | at_us: now,
        captured: stats.captured,
        rendered: stats.rendered,
        input_ppm: smooth(clock.input_ppm, -input),
        output_ppm: smooth(clock.output_ppm, output)
    }

    {{next.input_ppm, next.output_ppm}, next}
  end

  def sample(clock, _stats, _now), do: {nil, clock}

  defp estimate(frames, rate, elapsed),
    do: (frames * 1_000_000 / (rate * elapsed) - 1) * 1_000_000

  defp smooth(previous, measured),
    do: round(max(-1_000, min(1_000, previous * 0.95 + measured * 0.05)))
end
