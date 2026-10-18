defmodule Parlora.Channels.Browser.Media do
  @moduledoc false
  alias Parlora.{AudioFrame, AudioQueue, Event, Native, OutputSpace, Playout}
  alias Parlora.Channels.Browser.JitterBuffer
  alias Parlora.Channels.Browser.PlaybackDiagnostics
  alias Parlora.Native.Opus

  def open(init, options) do
    {:ok, encoder} = Opus.new(:encoder, 24_000, 1, 2048) |> Native.unwrap!()
    {:ok, decoder} = Opus.new(:decoder, 24_000, 1, 2048) |> Native.unwrap!()
    :ok = Opus.configure(encoder, 32_000, 5, 1, 10, 0, 1105) |> Native.unwrap!()

    %{
      encoder: encoder,
      decoder: decoder,
      input_pcm: <<>>,
      output_pcm: <<>>,
      output_waiter: nil,
      output_source?: false,
      input_active?: false,
      startup_discarded_packets: 0,
      startup_discarded_samples: 0,
      playback_diagnostics: %PlaybackDiagnostics{},
      jitter: %JitterBuffer{
        delay_us: options.jitter_ms * 1_000,
        max_packets: options.max_rtp_packets,
        max_age_us: options.max_age_ms * 1_000
      },
      inbound: %AudioQueue{capacity: init.limits.audio_queue_bytes},
      outbound: %AudioQueue{capacity: init.limits.audio_queue_bytes},
      playout:
        Playout.new(
          options.playback_buffer_ms,
          init.limits.audio_queue_bytes,
          Map.to_list(options)
        ),
      input_sequence: 0,
      sequence: :rand.uniform(65_536) - 1,
      timestamp: :rand.uniform(4_294_967_296) - 1,
      epoch: 0,
      suppressed: false,
      received: 0,
      sent: 0,
      rendered_source_bytes: 0,
      rendered_silence_bytes: 0,
      rendered_padding_bytes: 0,
      concealed: 0,
      discontinuities: %{},
      last_notice_us: %{}
    }
  end

  def receive_packet(state, packet, now) do
    case Opus.packet_info(packet.payload, 24_000) do
      {samples, _channels, _fec} when not state.media.input_active? ->
        update(state, %{
          startup_discarded_packets: state.media.startup_discarded_packets + 1,
          startup_discarded_samples: state.media.startup_discarded_samples + samples
        })

      {samples, _channels, _fec} ->
        case JitterBuffer.put(state.media.jitter, packet, samples, now) do
          {:ok, jitter} -> update(state, %{jitter: jitter, received: state.media.received + 1})
          {:drop, cause, jitter} -> discontinuity(update(state, %{jitter: jitter}), cause)
          {:error, reason} -> raise ErlangError, original: reason
        end

      {:error, _code} ->
        discontinuity(state, :malformed_opus)
    end
  end

  def capture(%{media: %{input_active?: false}} = state, _now), do: state

  def capture(state, now) do
    state = decode_due(state, now, 8)
    media = state.media
    {pcm, rest} = chunk(media.input_pcm)

    frame =
      AudioFrame.pcm(pcm, state.init.adapter_id, media.input_sequence,
        generation: state.init.generation,
        timestamp_us: now,
        clock: :local_monotonic
      )

    state = update(state, %{input_pcm: rest, input_sequence: media.input_sequence + 1})

    case AudioQueue.push(media.inbound, frame) do
      {:ok, queue} -> update(state, %{inbound: queue})
      {:error, _error} -> discontinuity(state, :capture_overflow)
    end
  end

  # The input pipeline's initial discard read is the readiness boundary. Before
  # that read, RTP is counted and discarded, never accumulated or decoded.
  def activate_input(%{media: %{input_active?: true}} = state), do: state

  def activate_input(state) do
    if state.media.startup_discarded_packets > 0 do
      observe(state, %{
        cause: :startup_capture_discard,
        boundary: :browser_rtp,
        packets: state.media.startup_discarded_packets,
        duration_us: div(state.media.startup_discarded_samples * 1_000_000, 24_000)
      })
    end

    update(state, %{input_active?: true})
  end

  def output(state, now) do
    state = fill_output(state, now)

    source_bytes =
      if state.media.output_source?, do: min(480, byte_size(state.media.output_pcm)), else: 0

    padding_bytes = if state.media.output_source?, do: 480 - source_bytes, else: 0
    {pcm, rest} = chunk(state.media.output_pcm)

    {diagnostics, observation} = output_observation(state, pcm, now)

    if observation, do: observe(state, observation)

    :telemetry.execute(
      [:parlora, :audio, :playout],
      %{
        at_us: now,
        source_bytes: source_bytes,
        source_peak: if(source_bytes > 0, do: diagnostics.last_peak, else: 0),
        source_position_bytes: state.media.rendered_source_bytes,
        epoch: state.media.epoch,
        silence_bytes: 480 - source_bytes,
        padding_bytes: padding_bytes,
        queue_bytes: state.media.outbound.bytes,
        staged_bytes: byte_size(state.media.output_pcm),
        playback_buffer_ms: state.media.playout.buffer_ms,
        playback_target_ms:
          if(state.media.playout.target,
            do: state.media.playout.target.target_ms,
            else: state.media.playout.buffer_ms
          ),
        recovery_cap_us: Playout.recovery_wait_us(state.media.playout),
        recovering: if(state.media.playout.recovering?, do: 1, else: 0),
        quiet_refill: if(Playout.quiet_refill?(state.media.playout), do: 1, else: 0),
        quiet_refills: Playout.quiet_refills(state.media.playout),
        starvations: state.media.playout.starvations
      },
      %{session_id: state.init.session_id, channel: :browser, epoch: state.media.epoch}
    )

    {:ok, payload} = Opus.encode(state.media.encoder, pcm, 240) |> Native.unwrap!()

    packet =
      ExRTP.Packet.new(payload,
        sequence_number: state.media.sequence,
        timestamp: state.media.timestamp
      )

    {packet,
     update(state, %{
       output_pcm: rest,
       playback_diagnostics: diagnostics,
       sent: state.media.sent + 1,
       rendered_source_bytes: state.media.rendered_source_bytes + source_bytes,
       rendered_silence_bytes: state.media.rendered_silence_bytes + 480 - source_bytes,
       rendered_padding_bytes: state.media.rendered_padding_bytes + padding_bytes,
       sequence: rem(state.media.sequence + 1, 65_536),
       timestamp: rem(state.media.timestamp + 480, 4_294_967_296)
     })}
  end

  defp output_observation(state, pcm, now) do
    {diagnostics, observation} =
      PlaybackDiagnostics.observe(
        state.media.playback_diagnostics,
        pcm,
        state.media.output_source?,
        now,
        state.media.epoch,
        if(Playout.quiet_refill?(state.media.playout),
          do: :quiet_refill,
          else: :source_queue_empty
        )
      )

    if Playout.quiet_refill?(state.media.playout) and state.media.outbound.bytes > 0 do
      diagnostics =
        PlaybackDiagnostics.source_available(
          diagnostics,
          now,
          state.media.outbound.bytes,
          Playout.wait_limit_us(state.media.playout, now)
        )

      {diagnostics, if(observation, do: PlaybackDiagnostics.snapshot(diagnostics, now).open_gap)}
    else
      {diagnostics, observation}
    end
  end

  def clear(state, epoch) do
    state = finish_gap(state, :cleared)
    :ok = Opus.reset(state.media.encoder) |> Native.unwrap!()

    update(state, %{
      outbound: AudioQueue.clear(state.media.outbound),
      output_pcm: <<>>,
      output_waiter: nil,
      output_source?: false,
      playback_diagnostics: PlaybackDiagnostics.reset(state.media.playback_diagnostics),
      playout: Playout.reset(state.media.playout),
      epoch: epoch
    })
  end

  def finish_gap(state, reason) do
    {diagnostics, observation} =
      PlaybackDiagnostics.finish(
        state.media.playback_diagnostics,
        reason,
        System.monotonic_time(:microsecond)
      )

    if observation, do: observe(state, observation)
    update(state, %{playback_diagnostics: diagnostics})
  end

  def release_recovery(%{media: %{epoch: epoch}} = state, epoch),
    do: update(state, %{playout: Playout.release_recovery(state.media.playout)})

  def release_recovery(state, _epoch), do: state

  def close(media) do
    Opus.close(media.encoder)
    Opus.close(media.decoder)
  end

  def update(state, changes), do: %{state | media: Map.merge(state.media, changes)}

  defp fill_output(%{media: %{output_pcm: pcm}} = state, _now) when byte_size(pcm) >= 480,
    do: state

  # A final partial packet is padded by chunk/1. Do not append a whole generated
  # silence packet or mislabel the remaining source samples as starvation.
  defp fill_output(%{media: %{output_pcm: pcm, outbound: %{bytes: 0}}} = state, _now)
       when byte_size(pcm) > 0,
       do: state

  defp fill_output(state, now) do
    bytes = state.media.outbound.bytes

    diagnostics =
      if bytes > 0,
        do:
          PlaybackDiagnostics.source_available(
            state.media.playback_diagnostics,
            now,
            bytes,
            Playout.wait_limit_us(state.media.playout, now)
          ),
        else: state.media.playback_diagnostics

    {pcm, queue, playout} =
      Playout.take(
        state.media.playout,
        state.media.outbound,
        state.init.limits.max_frame_bytes,
        now
      )

    diagnostics =
      if playout.source_bytes > state.media.playout.source_bytes,
        do: PlaybackDiagnostics.released(diagnostics, playout.release_reason, bytes),
        else: diagnostics

    update(state, %{
      playback_diagnostics: diagnostics,
      output_pcm: state.media.output_pcm <> pcm,
      output_source?: playout.source_bytes > state.media.playout.source_bytes,
      outbound: queue,
      playout: playout
    })
    |> then(fn state -> %{state | media: OutputSpace.notify(state.media)} end)
    |> fill_output(now)
  end

  defp decode_due(state, _now, 0), do: state

  defp decode_due(state, now, remaining) do
    case JitterBuffer.take(state.media.jitter, now) do
      {:wait, _jitter} ->
        state

      {:drop, cause, jitter} ->
        state
        |> update(%{jitter: jitter})
        |> discontinuity(cause)
        |> decode_due(now, remaining - 1)

      {:decode, packet, samples, fec?, jitter} ->
        decode(state, packet, samples, fec?, jitter) |> decode_due(now, remaining - 1)
    end
  end

  defp decode(state, packet, samples, fec?, jitter) do
    state = update(state, %{jitter: jitter})

    case Opus.decode(state.media.decoder, packet, samples, if(fec?, do: 1, else: 0)) do
      {:ok, pcm, _samples} ->
        state =
          if packet == nil or fec?,
            do:
              state
              |> update(%{concealed: state.media.concealed + 1})
              |> discontinuity(:packet_loss),
            else: state

        if byte_size(state.media.input_pcm) + byte_size(pcm) <=
             max(5_760, state.init.limits.audio_queue_bytes),
           do: update(state, %{input_pcm: state.media.input_pcm <> pcm}),
           else: discontinuity(state, :decoded_overflow)

      {:error, -4} ->
        discontinuity(state, :malformed_opus)

      error ->
        Native.unwrap!(error)
    end
  end

  defp chunk(<<pcm::binary-size(480), rest::binary>>), do: {pcm, rest}
  defp chunk(pcm), do: {pcm <> :binary.copy(<<0>>, 480 - byte_size(pcm)), <<>>}

  defp observe(state, payload) do
    Event.emit(state.init, :channel, :audio_observed, payload)

    if payload.boundary == :browser_pcm do
      at_us = payload.started_at_us + payload.duration_us

      :telemetry.execute([:parlora, :audio, :playout_gap], Map.put(payload, :at_us, at_us), %{
        session_id: state.init.session_id,
        channel: :browser
      })
    end
  end

  defp discontinuity(state, cause) do
    now = System.monotonic_time(:microsecond)
    counts = Map.update(state.media.discontinuities, cause, 1, &(&1 + 1))
    last = Map.get(state.media.last_notice_us, cause, now - 250_000)
    state = update(state, %{discontinuities: counts})

    if now - last >= 250_000 do
      Event.emit(state.init, :channel, :audio_discontinuity, %{
        cause: cause,
        epoch: state.media.epoch,
        total_count: counts[cause]
      })

      update(state, %{last_notice_us: Map.put(state.media.last_notice_us, cause, now)})
    else
      state
    end
  end
end
