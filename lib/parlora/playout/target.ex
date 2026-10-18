defmodule Parlora.Playout.Target do
  @moduledoc false

  # Receipt groups, not pipeline fragments, are the samples. All clocks and
  # durations here are local source observations, never remote RTP timestamps.
  @window_us 5_000_000
  @idle_us 1_000_000
  @history_limit 128
  @margin_ms 20
  @decrease_ms 10

  defstruct floor_ms: 120,
            ceiling_ms: 200,
            target_ms: 120,
            group: nil,
            position_us: 0,
            transit_us: 0,
            transits: [],
            delays: [],
            stable_us: 0,
            increases: 0,
            decreases: 0,
            idle_resets: 0,
            clock_resets: 0

  def new(floor, ceiling),
    do: %__MODULE__{floor_ms: floor, ceiling_ms: ceiling, target_ms: floor}

  # Clear/suppression break the timing baseline, but retain the learned target.
  def reset(state),
    do: %{
      state
      | group: nil,
        position_us: 0,
        transit_us: 0,
        transits: [],
        delays: []
    }

  def observe(state, %{clock: :local_monotonic, timestamp_us: at} = frame, starved?)
      when is_integer(at) do
    identity = {frame.stream_id, frame.generation}

    cond do
      frame.discontinuity ->
        start(reset(state), frame, identity)

      state.group == nil ->
        start(state, frame, identity)

      state.group.identity != identity or at < state.group.at ->
        start(
          %{reset(state) | clock_resets: state.clock_resets + 1, stable_us: 0},
          frame,
          identity
        )

      at == state.group.at ->
        %{state | group: %{state.group | duration: state.group.duration + frame.duration_us}}

      at - state.group.at - state.group.duration >= @idle_us ->
        start(%{reset(state) | idle_resets: state.idle_resets + 1}, frame, identity)

      true ->
        sample(state, frame, identity, starved?)
    end
  end

  # Unknown/provider clocks cannot be compared to the local playout clock.
  def observe(state, _frame, _starved), do: %{reset(state) | stable_us: 0}

  defp start(state, frame, identity) do
    transits = if state.group == nil, do: [{0, 0}], else: state.transits

    %{
      state
      | group: %{at: frame.timestamp_us, duration: frame.duration_us, identity: identity},
        transits: transits
    }
  end

  defp sample(state, frame, identity, starved?) do
    position = state.position_us + state.group.duration
    transit = state.transit_us + frame.timestamp_us - state.group.at - state.group.duration
    transits = retain([{position, transit} | state.transits], position)
    delay = max(0, transit - Enum.min(Enum.map(transits, &elem(&1, 1))))
    delays = retain([{position, delay} | state.delays], position)
    sorted = delays |> Enum.map(&elem(&1, 1)) |> Enum.sort()
    percentile = Enum.at(sorted, ceil(length(sorted) * 0.95) - 1)
    # A confirmed empty source queue reacts promptly; one late receipt while
    # audio remains queued is handled by the recent 95th percentile instead.
    estimate = if starved?, do: max(delay, percentile), else: percentile
    desired = min(state.ceiling_ms, max(state.floor_ms, ceil(estimate / 1_000) + @margin_ms))
    stable = if desired < state.target_ms, do: state.stable_us + state.group.duration, else: 0

    {target, stable, increases, decreases} =
      cond do
        desired > state.target_ms ->
          {desired, 0, state.increases + 1, state.decreases}

        stable >= @window_us ->
          {max(desired, state.target_ms - @decrease_ms), 0, state.increases, state.decreases + 1}

        true ->
          {state.target_ms, stable, state.increases, state.decreases}
      end

    start(
      %{
        state
        | position_us: position,
          transit_us: transit,
          transits: transits,
          delays: delays,
          target_ms: target,
          stable_us: stable,
          increases: increases,
          decreases: decreases
      },
      frame,
      identity
    )
  end

  defp retain(history, now),
    do:
      history |> Enum.take_while(&(now - elem(&1, 0) <= @window_us)) |> Enum.take(@history_limit)
end
