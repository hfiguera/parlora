defmodule Parlora.Channels.Browser do
  @moduledoc """
  One browser audio connection, terminated at Parlora with ExWebRTC and libopus.

  Supply `:signaling` as the owning signaling process. It receives
  `{:parlora_browser, channel_pid, {:signal, json_map}}`; submit the browser's
  offer and ICE candidates with `signal/2` from that same process. Its death
  closes the channel. Only one audio offer is supported per session.

  Options: `:ice_servers` (default `[]`), `:ice_transport_policy` (`:all` or
  `:relay`, default `:all`), `:jitter_ms` (40),
  `:playback_buffer_ms` (120), `:playback_buffering` (`:adaptive` or `:fixed`,
  default `:adaptive`), `:playback_recovery_ms` (120),
  `:max_rtp_packets` (32), `:max_age_ms` (200),
  and `:max_mailbox` (256). Bounds reject overload rather than growing queues.
  Adaptive playback learns a target between the initial cushion and 200 ms,
  capped by queue duration. Recovery waiting has its own cap; zero initial
  cushion disables buffering. See the [browser guide](browser-channel.html).
  Clear affects Parlora buffers; packets already handed to ExWebRTC and browser
  or OS buffers cannot be recalled. Handoff does not confirm audibility.
  """
  use GenServer
  use Parlora.AdapterClient, output_space: true
  @behaviour Parlora.Channel
  alias ExWebRTC.{ICECandidate, MediaStreamTrack, PeerConnection, SessionDescription}

  alias Parlora.{
    Adapter,
    AudioFormat,
    AudioFrame,
    AudioQueue,
    CommandLog,
    Error,
    Event,
    Native,
    OutputSpace,
    Pacer,
    Playout
  }

  alias Parlora.Channel.Capabilities
  alias Parlora.Channels.Browser.Media
  alias Parlora.Channels.Browser.PlaybackDiagnostics

  @defaults %{
    jitter_ms: 40,
    playback_buffer_ms: 120,
    playback_buffering: :adaptive,
    playback_recovery_ms: 120,
    max_rtp_packets: 32,
    max_age_ms: 200,
    max_mailbox: 256
  }

  @impl true
  def start_link(init, options) do
    settings = Map.merge(@defaults, Map.new(Keyword.take(options, Map.keys(@defaults))))
    owner = Keyword.get(options, :signaling)

    if is_pid(owner) and valid_settings?(settings, init.limits) and
         Keyword.get(options, :ice_transport_policy, :all) in [:all, :relay],
       do: GenServer.start_link(__MODULE__, {init, owner, settings, options}),
       else: Error.tuple(:invalid_argument, "Browser requires a signaling owner and valid bounds")
  end

  @doc """
  Admits one offer or ICE candidate from the channel's signaling owner.

  After receiving `{:parlora_browser, channel, :attached}`, submit string-keyed maps:

      %{"type" => "offer", "sdp" => offer_sdp}
      %{"type" => "candidate", "candidate" => %{
        "candidate" => candidate_string, "sdpMid" => "0", "sdpMLineIndex" => 0
      }}

  Send the offer before its candidates. The SDP must negotiate one bidirectional
  Opus audio track. `sdpMid` may be nil; optional `usernameFragment` is forwarded.
  Ignore the browser's null end-of-gathering candidate. Admission is asynchronous;
  observe channel events for negotiation failure and session readiness.

  See the [browser handshake and JavaScript client](browser-channel.html#signaling-messages)
  for the WebSocket envelopes used by `Parlora.Channels.Browser.Signaling`.
  """
  def signal(pid, message), do: Adapter.call(pid, {:signal, message})

  @doc "Bounded media counters; sent packets are not confirmed playback."
  def observations(pid), do: Adapter.call(pid, :observations)

  @impl true
  def release_output_recovery(pid, epoch),
    do: Adapter.call(pid, {:release_output_recovery, epoch})

  @impl true
  def init({init, owner, settings, options}) do
    Process.flag(:trap_exit, true)
    Process.monitor(owner)
    Process.send_after(self(), :connect_timeout, init.limits.startup_timeout_ms)

    if init.audio_format == %AudioFormat{} do
      state = %{
        init: init,
        owner: owner,
        settings: settings,
        options: options,
        status: :starting,
        pc: nil,
        media: nil,
        track: nil,
        input_track: nil,
        offered?: false,
        signals: 0,
        commands: %CommandLog{limit: init.limits.max_records},
        deadline: System.monotonic_time(:microsecond),
        max_tick_gap_us: 0,
        last_tick: nil
      }

      {:ok, state, {:continue, :open}}
    else
      {:stop, Error.new(:unsupported, "Browser requires mono PCM16LE at 24 kHz")}
    end
  end

  @impl true
  def handle_continue(:open, state) do
    case Native.call(fn -> Media.open(state.init, state.settings) end) do
      {:ok, media} ->
        options = [
          audio_codecs: [:opus],
          video_codecs: [],
          features: [:rtcp_reports],
          ice_servers: Keyword.get(state.options, :ice_servers, []),
          ice_transport_policy: Keyword.get(state.options, :ice_transport_policy, :all)
        ]

        {:ok, pc} = PeerConnection.start_link(options)
        track = MediaStreamTrack.new(:audio)
        {:ok, _sender} = PeerConnection.add_track(pc, track)
        send(state.owner, {:parlora_browser, self(), :attached})
        {:noreply, %{state | pc: pc, track: track.id, media: media, options: []}}

      {:error, error} ->
        fail(state, error)
    end
  end

  @impl true
  def handle_call({:close, id, _reason}, _from, state) do
    state = if state.media, do: Media.finish_gap(state, :closed), else: state

    if state.status != :closed do
      cleanup(state)
      Event.emit(state.init, :channel, :closed, %{}, command_id: id)
    end

    {:reply, :ok, %{state | status: :closed}}
  end

  def handle_call(:capabilities, _from, state), do: {:reply, {:ok, capabilities()}, state}

  def handle_call({:signal, message}, {owner, _tag}, %{owner: owner} = state)
      when state.status in [:starting, :ready] and state.signals < 128 do
    if valid_signal?(message) do
      send(self(), {:apply_signal, message})
      {:reply, :ok, %{state | signals: state.signals + 1}}
    else
      {:reply, Error.tuple(:invalid_argument, "Invalid browser signaling message"), state}
    end
  end

  def handle_call(_message, _from, %{status: status} = state) when status != :ready,
    do: {:reply, Error.tuple(:not_ready, "Browser media is not ready"), state}

  def handle_call(:observations, _from, state) do
    counters =
      Map.take(state.media, [
        :received,
        :sent,
        :concealed,
        :discontinuities,
        :epoch,
        :rendered_source_bytes,
        :rendered_silence_bytes,
        :rendered_padding_bytes
      ])

    {:reply,
     Map.merge(counters, %{
       rtp_queued: map_size(state.media.jitter.packets),
       input_bytes: state.media.inbound.bytes + byte_size(state.media.input_pcm),
       output_bytes: state.media.outbound.bytes + byte_size(state.media.output_pcm),
       max_tick_gap_us: state.max_tick_gap_us,
       playback_starvations: state.media.playout.starvations,
       playback_source_bytes: state.media.playout.source_bytes,
       playback_silence_bytes: state.media.playout.silence_bytes
     })
     |> Map.merge(Playout.snapshot(state.media.playout))
     |> Map.merge(
       PlaybackDiagnostics.snapshot(
         state.media.playback_diagnostics,
         System.monotonic_time(:microsecond)
       )
     )
     |> Map.merge(
       Map.take(state.media, [
         :input_active?,
         :startup_discarded_packets,
         :startup_discarded_samples
       ])
     ), state}
  end

  def handle_call({:release_output_recovery, epoch}, _from, state),
    do: {:reply, :ok, Media.release_recovery(state, epoch)}

  def handle_call({:arm_output_space, writer, reference, bytes, epoch}, _from, state)
      when is_pid(writer) and is_reference(reference) and is_integer(bytes) and bytes > 0 do
    media = OutputSpace.arm(state.media, writer, reference, bytes, epoch)
    {:reply, :ok, %{state | media: media}}
  end

  def handle_call({:read, budget}, _from, state) do
    {:reply, reply, media} =
      AudioQueue.reply_read(Map.put(state.media, :init, state.init), budget)

    state = %{state | media: Map.delete(media, :init)}

    state =
      case reply do
        {:ok, _frames} -> Media.activate_input(state)
        _error -> state
      end

    {:reply, reply, state}
  end

  def handle_call({:write, frame}, _from, state) do
    with :ok <- AudioFrame.validate(frame, state.init.audio_format, state.init.limits),
         true <- frame.playback_epoch == state.media.epoch,
         {:ok, queue} <- admit_output(state, frame) do
      unless state.media.suppressed do
        Event.emit(state.init, :channel, :playback_observed, %{
          stage: :queued,
          evidence: :queue,
          epoch: state.media.epoch,
          sequence: frame.sequence
        })
      end

      playout =
        if state.media.suppressed,
          do: state.media.playout,
          else: Playout.observe(state.media.playout, frame)

      {:reply, :ok, Media.update(state, %{outbound: queue, playout: playout})}
    else
      false -> {:reply, Error.tuple(:invalid_argument, "Stale playback epoch"), state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:control, id, control}, _from, state) do
    CommandLog.run(state, id, control, &control_result/3)
  end

  def handle_call(_message, _from, state),
    do: {:reply, Error.tuple(:invalid_argument, "Invalid browser command"), state}

  @impl true
  def handle_info({:apply_signal, message}, state) when state.status in [:starting, :ready] do
    case apply_signal(state, message) do
      {:ok, next} -> {:noreply, next}
      {:error, _reason} -> fail(state, Error.new(:adapter_failed, "WebRTC signaling failed"))
    end
  end

  def handle_info({:ex_webrtc, pc, {:ice_candidate, candidate}}, %{pc: pc} = state) do
    emit_signal(state, %{"type" => "candidate", "candidate" => ICECandidate.to_json(candidate)})
    {:noreply, state}
  end

  def handle_info({:ex_webrtc, pc, {:track, %{kind: :audio, id: id}}}, %{pc: pc} = state),
    do: {:noreply, %{state | input_track: id}}

  def handle_info(
        {:ex_webrtc, pc, {:connection_state_change, :connected}},
        %{pc: pc, status: :starting} = state
      ) do
    Event.emit(state.init, :channel, :ready, %{
      capabilities: capabilities(),
      format: state.init.audio_format
    })

    send(self(), :tick)
    {:noreply, %{state | status: :ready, deadline: System.monotonic_time(:microsecond)}}
  end

  def handle_info({:ex_webrtc, pc, {:connection_state_change, status}}, %{pc: pc} = state)
      when status in [:failed, :disconnected, :closed] and state.status != :closed,
      do: fail(state, Error.new(:adapter_failed, "Browser media disconnected"))

  def handle_info(
        {:ex_webrtc, pc, {:rtp, track, nil, packet}},
        %{pc: pc, input_track: track, status: :ready} = state
      ) do
    if byte_size(packet.payload) in 1..8192 do
      safe_media(state, fn ->
        Media.receive_packet(state, packet, System.monotonic_time(:microsecond))
      end)
    else
      Event.emit(state.init, :channel, :audio_discontinuity, %{cause: :malformed_opus})
      {:noreply, state}
    end
  end

  def handle_info(:connect_timeout, %{status: :starting} = state),
    do: fail(state, Error.new(:timeout, "Browser negotiation timed out"))

  def handle_info(:tick, %{status: :ready} = state) do
    if overloaded?(state) do
      fail(state, Error.new(:backpressure, "Browser media mailbox limit exceeded"))
    else
      safe_media(state, fn -> tick(state) end)
    end
  end

  def handle_info({:DOWN, _ref, :process, owner, _reason}, %{owner: owner} = state),
    do: fail(state, Error.new(:closed, "Browser signaling disconnected"))

  def handle_info({:EXIT, pc, _reason}, %{pc: pc, status: status} = state) when status != :closed,
    do: fail(state, Error.new(:adapter_failed, "WebRTC process exited"))

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.media, do: Media.finish_gap(state, :closed)
    cleanup(state)
  end

  @impl true
  def format_status(status),
    do:
      Map.merge(status, %{state: Map.take(status.state, [:status, :settings]), message: :redacted})

  defp capabilities, do: %{Capabilities.buffered_pcm() | output_pacing: :channel}

  defp valid_settings?(s, limits) do
    Enum.all?(Map.drop(s, [:playback_buffering]), fn {_key, value} -> is_integer(value) end) and
      s.jitter_ms in 0..200 and s.playback_buffer_ms in 0..200 and
      s.max_rtp_packets in 2..128 and s.max_age_ms in 40..1_000 and s.max_mailbox in 32..2_048 and
      Playout.valid_options?(s.playback_buffer_ms, limits.audio_queue_bytes, Map.to_list(s))
  end

  defp valid_signal?(%{"type" => "offer", "sdp" => sdp}) when is_binary(sdp),
    do: byte_size(sdp) in 1..65_536

  defp valid_signal?(%{"type" => "candidate", "candidate" => candidate}) when is_map(candidate) do
    is_binary(candidate["candidate"]) and byte_size(candidate["candidate"]) <= 4_096 and
      (is_binary(candidate["sdpMid"]) or is_nil(candidate["sdpMid"])) and
      candidate["sdpMLineIndex"] == 0
  end

  defp valid_signal?(_message), do: false

  defp apply_signal(%{offered?: false} = state, %{"type" => "offer", "sdp" => sdp}) do
    with {:ok, parsed} <- ExSDP.parse(sdp),
         [%{type: :audio}] <- parsed.media,
         :ok <-
           PeerConnection.set_remote_description(state.pc, %SessionDescription{
             type: :offer,
             sdp: sdp
           }),
         {:ok, answer} <- PeerConnection.create_answer(state.pc),
         :ok <- PeerConnection.set_local_description(state.pc, answer),
         [%{current_direction: :sendrecv}] <- PeerConnection.get_transceivers(state.pc) do
      emit_signal(state, SessionDescription.to_json(answer))
      {:ok, %{state | offered?: true}}
    else
      _invalid -> {:error, :invalid_offer}
    end
  end

  defp apply_signal(%{offered?: true} = state, %{"type" => "candidate", "candidate" => candidate}) do
    case PeerConnection.add_ice_candidate(state.pc, ICECandidate.from_json(candidate)) do
      :ok -> {:ok, state}
      error -> error
    end
  end

  defp apply_signal(_state, _message), do: {:error, :invalid_signaling_order}

  defp emit_signal(state, message),
    do: send(state.owner, {:parlora_browser, self(), {:signal, message}})

  defp admit_output(%{media: %{suppressed: true}} = state, _frame),
    do: {:ok, state.media.outbound}

  defp admit_output(state, frame), do: AudioQueue.push(state.media.outbound, frame)

  defp control_result(state, id, control) do
    case Native.call(fn -> apply_control(state, control) end) do
      {:ok, {:ok, next, payload}} ->
        Event.emit(state.init, :channel, :control_completed, payload, command_id: id)
        {:reply, :ok, next}

      {:ok, error} ->
        {:reply, error, state}

      {:error, error} ->
        Event.emit(state.init, :channel, :failed, %{error: error})
        {:reply, {:error, error}, state}
    end
  end

  defp apply_control(state, {:suppress_output, flag}) when is_boolean(flag) do
    state = Media.clear(state, state.media.epoch)

    {:ok, Media.update(state, %{suppressed: flag}),
     %{control: :suppress_output, suppressed: flag}}
  end

  defp apply_control(state, {:clear_output, epoch})
       when is_integer(epoch) and epoch > state.media.epoch,
       do:
         {:ok, Media.clear(state, epoch),
          %{control: :clear_output, scope: :parlora_buffers, epoch: epoch}}

  defp apply_control(_state, _control),
    do: Error.tuple(:unsupported, "Unsupported browser control")

  defp tick(state) do
    now = System.monotonic_time(:microsecond)

    state = %{
      state
      | last_tick: now,
        max_tick_gap_us: max(state.max_tick_gap_us, now - (state.last_tick || now))
    }

    {packet, state} = state |> Media.capture(now) |> Media.output(now)
    :ok = PeerConnection.send_rtp(state.pc, state.track, packet)

    Event.emit(state.init, :channel, :playback_observed, %{
      stage: :handed_off,
      evidence: :handoff,
      epoch: state.media.epoch,
      sequence: packet.sequence_number,
      boundary: :ex_webrtc_admission,
      source_audio?: state.media.output_source?
    })

    {deadline, wait} = Pacer.next(state.deadline, 10_000)
    Process.send_after(self(), :tick, wait)
    %{state | deadline: deadline}
  end

  defp overloaded?(state) do
    Enum.any?([self(), state.pc, state.owner], fn pid ->
      case Process.info(pid, :message_queue_len) do
        {:message_queue_len, size} -> size > state.settings.max_mailbox
        nil -> true
      end
    end)
  end

  defp safe_media(state, function) do
    case Native.call(function) do
      {:ok, next} -> {:noreply, next}
      {:error, error} -> fail(state, error)
    end
  end

  defp fail(%{status: :closed} = state, _error), do: {:noreply, state}

  defp fail(state, error) do
    Event.emit(state.init, :channel, :failed, %{error: error})
    {:stop, :normal, state}
  end

  defp cleanup(state) do
    if state.media, do: Media.close(state.media)
    if state.pc && Process.alive?(state.pc), do: GenServer.stop(state.pc, :normal, 1_000)
    :ok
  catch
    :exit, _reason ->
      if state.pc, do: Process.exit(state.pc, :kill)
      :ok
  end
end
