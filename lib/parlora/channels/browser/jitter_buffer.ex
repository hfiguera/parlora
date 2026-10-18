defmodule Parlora.Channels.Browser.JitterBuffer do
  @moduledoc false
  # RTP timestamps, including mono/24 kHz Opus, always use a 48 kHz clock.
  defstruct packets: %{},
            expected: nil,
            timestamp: nil,
            anchor: nil,
            ssrc: nil,
            delay_us: 40_000,
            max_packets: 32,
            max_age_us: 200_000,
            started?: false

  def put(state, packet, samples, now) do
    state = initialize(state, packet, now)
    sequence = extend(packet.sequence_number, state.expected, 65_536)
    timestamp = extend(packet.timestamp, state.timestamp, 4_294_967_296)

    cond do
      packet.ssrc != state.ssrc ->
        {:drop, :unexpected_ssrc, state}

      sequence < state.expected and state.started? ->
        {:drop, :late_packet, state}

      Map.has_key?(state.packets, sequence) ->
        {:drop, :duplicate_packet, state}

      map_size(state.packets) >= state.max_packets ->
        {:drop, :rtp_overflow, state}

      outside_window?(state, sequence, timestamp, now) ->
        {:error, :rtp_timeline_jump}

      true ->
        insert(state, sequence, timestamp, packet.payload, samples)
    end
  end

  defp outside_window?(state, sequence, timestamp, now),
    do:
      abs(sequence - state.expected) > state.max_packets * 4 or
        state.anchor + div(timestamp * 1_000_000, 48_000) >
          now + state.delay_us + state.max_age_us

  defp insert(state, sequence, timestamp, payload, samples) do
    entry = %{payload: payload, timestamp: timestamp, samples: samples}
    state = %{state | packets: Map.put(state.packets, sequence, entry)}

    state =
      if not state.started? and sequence < state.expected,
        do: %{state | expected: sequence, timestamp: timestamp},
        else: state

    {:ok, state}
  end

  def take(%{packets: packets} = state, _now) when map_size(packets) == 0,
    do: {:wait, state}

  def take(state, now) do
    {sequence, packet} = Enum.min_by(state.packets, fn {seq, _packet} -> seq end)
    due = state.anchor + div(packet.timestamp * 1_000_000, 48_000)

    cond do
      now - due > state.max_age_us ->
        {:drop, :late_packet,
         %{
           state
           | packets: Map.delete(state.packets, sequence),
             expected: sequence + 1,
             timestamp: packet.timestamp + packet.samples * 2,
             started?: true
         }}

      sequence == state.expected and now < due ->
        {:wait, state}

      sequence == state.expected ->
        next = %{
          state
          | packets: Map.delete(state.packets, sequence),
            expected: sequence + 1,
            timestamp: packet.timestamp + packet.samples * 2,
            started?: true
        }

        {:decode, packet.payload, packet.samples, false, next}

      now < state.anchor + div(state.timestamp * 1_000_000, 48_000) ->
        {:wait, state}

      true ->
        conceal(state, sequence, packet)
    end
  end

  defp conceal(state, sequence, packet) do
    gap = packet.timestamp - state.timestamp
    # A timestamp gap may include DTX. Never allocate or synthesize an unbounded gap.
    samples = min(480, max(60, div(gap, 2 * max(1, sequence - state.expected))))
    samples = div(samples, 60) * 60
    fec? = sequence == state.expected + 1 and samples == 480 and gap == 960

    next = %{
      state
      | expected: state.expected + 1,
        timestamp: state.timestamp + samples * 2,
        started?: true
    }

    {:decode, if(fec?, do: packet.payload, else: nil), samples, fec?, next}
  end

  defp initialize(%{expected: nil} = state, packet, now) do
    %{
      state
      | expected: packet.sequence_number,
        timestamp: packet.timestamp,
        ssrc: packet.ssrc,
        anchor: now + state.delay_us - div(packet.timestamp * 1_000_000, 48_000)
    }
  end

  defp initialize(state, _packet, _now), do: state

  defp extend(value, reference, modulus) do
    reference + Integer.mod(value - reference + div(modulus, 2), modulus) - div(modulus, 2)
  end
end
