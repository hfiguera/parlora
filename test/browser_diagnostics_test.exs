defmodule Parlora.BrowserDiagnosticsTest do
  use ExUnit.Case, async: true
  alias Parlora.{AdapterInit, AudioFormat, AudioFrame, AudioQueue, Event, Limits}
  alias Parlora.Channels.Browser
  alias Parlora.Channels.Browser.{Media, PlaybackDiagnostics, Signaling}
  alias Parlora.Playout.Target

  test "backend uncertainty reaches browser diagnostics with a bounded reason and no raw error" do
    for {reason, expected} <- [
          {:framework_failure, "framework_failure"},
          {"private error", "unknown"}
        ] do
      event = %Event{
        source: :backend,
        type: :request_uncertain,
        request_id: "lookup",
        payload: %{reason: reason, error: %{message: "private Lua and model data"}}
      }

      assert {:push, {:text, encoded}, %{}} = Signaling.handle_info({:parlora_event, event}, %{})
      message = Jason.decode!(encoded)
      assert message["event"] == "request_uncertain"
      assert message["request_id"] == "lookup"
      assert message["payload"] == %{"reason" => expected}
      refute encoded =~ "private"
    end
  end

  test "response delay status reaches the browser without transcripts or raw provider data" do
    event = %Parlora.Event{
      source: :provider,
      type: :response_status,
      payload: %{
        status: :delayed,
        cause: :caller_caption,
        elapsed_ms: 12_003,
        evidence: :local_observation,
        private_detail: "not for the browser"
      }
    }

    assert {:push, {:text, encoded}, %{}} = Signaling.handle_info({:parlora_event, event}, %{})
    message = Jason.decode!(encoded)
    assert message["event"] == "response_status"
    assert message["payload"]["status"] == "delayed"
    assert message["payload"]["elapsed_ms"] == 12_003
    refute Map.has_key?(message["payload"], "private_detail")
  end

  test "signaling retains caption segment identity without adding timing" do
    event = %Event{
      type: :transcript_delta,
      payload: %{
        speaker: :assistant,
        delta: "Saved.",
        segment_id: "reply-2",
        start_ms: nil,
        end_ms: nil
      }
    }

    assert {:push, {:text, encoded}, %{}} = Signaling.handle_info({:parlora_event, event}, %{})

    assert %{"payload" => %{"segment_id" => "reply-2", "delta" => "Saved."}} =
             Jason.decode!(encoded)
  end

  test "signaling preserves GPT Live timeline intervals for browser caption grouping" do
    event = %Event{
      type: :transcript_delta,
      payload: %{
        speaker: :assistant,
        delta: "Saved.",
        start_ms: 15_000,
        end_ms: 17_000,
        private_detail: "not for the browser"
      }
    }

    assert {:push, {:text, encoded}, %{}} = Signaling.handle_info({:parlora_event, event}, %{})

    assert Jason.decode!(encoded)["payload"] == %{
             "speaker" => "assistant",
             "delta" => "Saved.",
             "start_ms" => 15_000,
             "end_ms" => 17_000
           }
  end

  alias Parlora.Native.Opus

  setup do
    init = %AdapterInit{
      session_id: "diagnostic-probe",
      adapter_id: "browser-probe",
      generation: 0,
      event_sink: self(),
      audio_format: %AudioFormat{},
      limits: %Limits{}
    }

    media =
      Media.open(init, %{
        jitter_ms: 0,
        max_rtp_packets: 32,
        max_age_ms: 200,
        playback_buffer_ms: 120
      })

    on_exit(fn -> Media.close(media) end)
    {:ok, state: %{init: init, media: media, status: :ready}}
  end

  test "startup discards RTP with bounded counters; first valid read activates fresh capture", %{
    state: state
  } do
    {:ok, payload} = Opus.encode(state.media.encoder, :binary.copy(<<0>>, 960), 480)
    packet = ExRTP.Packet.new(payload, sequence_number: 0, timestamp: 0, ssrc: 1)

    starting =
      Enum.reduce(0..99, state, fn tick, acc ->
        packet = %{packet | sequence_number: tick, timestamp: tick * 960}
        acc |> Media.receive_packet(packet, tick * 20_000) |> Media.capture(tick * 20_000)
      end)

    assert starting.media.startup_discarded_packets == 100
    assert starting.media.startup_discarded_samples == 48_000
    assert starting.media.inbound.bytes == 0
    assert starting.media.input_pcm == <<>>
    assert starting.media.jitter.packets == %{}
    assert starting.media.discontinuities == %{}

    assert {:reply, {:error, _}, ^starting} = Browser.handle_call({:read, 1}, nil, starting)
    assert {:reply, {:ok, []}, active} = Browser.handle_call({:read, 9_600}, nil, starting)
    assert active.media.input_active?

    assert_receive {:parlora_event,
                    %Event{
                      type: :audio_observed,
                      payload: %{
                        cause: :startup_capture_discard,
                        packets: 100,
                        duration_us: 2_000_000
                      }
                    }}

    fresh = active |> Media.receive_packet(packet, 2_000_000) |> Media.capture(2_000_000)
    assert fresh.media.inbound.bytes == 480
    assert fresh.media.received == 1
    assert {:reply, {:ok, [_frame]}, _next} = Browser.handle_call({:read, 960}, nil, fresh)
    refute_receive {:parlora_event, %Event{type: :audio_observed}}
  end

  test "idle startup generates no capture warnings; ready capture overload remains visible", %{
    state: state
  } do
    starting = Enum.reduce(0..999, state, &Media.capture(&2, &1 * 10_000))
    assert starting == state
    active = Media.activate_input(starting)
    overflow = Enum.reduce(0..24, active, &Media.capture(&2, &1 * 10_000))
    assert overflow.media.discontinuities == %{capture_overflow: 5}
    assert overflow.media.inbound.bytes == 9_600

    assert_receive {:parlora_event,
                    %Event{type: :audio_discontinuity, payload: %{cause: :capture_overflow}}}
  end

  for sample <- [0, 1_000] do
    test "finite clip with sample #{sample} ends with an observation, not a discontinuity", %{
      state: state
    } do
      played = play(enqueue(state, unquote(sample)), 0..11)
      assert played.media.playout.source_bytes == 5_760
      assert played.media.playout.silence_bytes == 0
      assert played.media.output_pcm == <<>>
      assert played.media.playback_diagnostics.count == 0

      ended = play(played, 12..112)
      assert ended.media.discontinuities == %{}
      assert ended.media.playback_diagnostics.count == 1
      assert ended.media.playback_diagnostics.gap.silence_bytes == 101 * 480

      assert_receive {:parlora_event,
                      %Event{
                        type: :audio_observed,
                        payload: %{
                          cause: :source_queue_empty,
                          peak_before: unquote(sample),
                          peak_after: nil
                        }
                      }}

      refute_receive {:parlora_event, %Event{type: :audio_discontinuity}}
      refute_receive {:parlora_event, %Event{type: :audio_observed}}
    end
  end

  test "gap summaries measure actual 10 ms output blocks including adaptive recovery wait", %{
    state: state
  } do
    # max_frame_bytes=960: each queue read contains two output packets. Peaks and
    # emptiness must be measured at packet consumption, not early at queue pop.
    played = play(enqueue(state, 1_000), 0..12)
    resumed = play(enqueue(played, 2_000), 13..13)
    assert resumed.media.playout.silence_bytes == 480
    assert resumed.media.playout.source_bytes == 6_720
    summary = resumed.media.playback_diagnostics.last_gap
    assert summary.cause == :source_resumed
    assert summary.duration_us == 10_000
    assert summary.inserted_silence_us == 10_000
    assert summary.peak_before == 1_000
    assert summary.peak_after == 2_000
    assert summary.source_returned_at_us == 130_000
    assert summary.source_unavailable_us == 10_000
    assert summary.recovery_wait_us == 0
    assert summary.recovery_target_us == 120_000
    assert summary.source_return_queue_bytes == 5_760
    assert summary.resume_queue_bytes == 5_760
    assert summary.recovery_release_reason == :queue_ready
    assert summary.epoch == 0
    assert resumed.media.playback_diagnostics.gap == nil
    assert resumed.media.discontinuities == %{}
  end

  test "medium shortage is separated from a fixed refill wait and pressure releases it", %{
    state: state
  } do
    empty = play(enqueue(state, 4_960), 0..28)
    returned = play(enqueue(empty, 5_344, 2), 29..29)
    open = PlaybackDiagnostics.snapshot(returned.media.playback_diagnostics, 300_000).open_gap
    assert open.source_unavailable_us == 170_000
    assert open.recovery_wait_us == 10_000
    assert open.recovery_release_reason == nil

    resumed = play(returned, 30..41)
    gap = resumed.media.playback_diagnostics.last_gap
    assert gap.inserted_silence_us == 290_000
    assert gap.source_unavailable_us == 170_000
    assert gap.recovery_wait_us == 120_000
    assert gap.recovery_release_reason == :deadline

    released = returned |> Media.release_recovery(0) |> play(30..30)
    gap = released.media.playback_diagnostics.last_gap
    assert gap.source_unavailable_us == 170_000
    assert gap.recovery_wait_us == 10_000
    assert gap.recovery_release_reason == :pressure
    assert gap.source_return_queue_bytes == gap.resume_queue_bytes

    {_diagnostics, closed} =
      PlaybackDiagnostics.finish(returned.media.playback_diagnostics, :closed, 310_000)

    assert closed.source_unavailable_us == 170_000
    assert closed.recovery_wait_us == 20_000
    assert closed.recovery_release_reason == :closed
    assert closed.resume_queue_bytes == nil
  end

  test "zero buffer reports immediate source return and clear removes prior recovery evidence", %{
    state: state
  } do
    state = put_in(state.media.playout, Parlora.Playout.new(0, 9_600))
    empty = play(enqueue(state, 1_000), 0..12)
    resumed = play(enqueue(empty, 2_000), 13..13)
    gap = resumed.media.playback_diagnostics.last_gap
    assert gap.source_unavailable_us == 10_000
    assert gap.recovery_wait_us == 0
    assert gap.recovery_release_reason == :buffering_disabled
    cleared = Media.clear(resumed, 1)
    assert cleared.media.playout.release_reason == nil
    assert cleared.media.playback_diagnostics.gap == nil
  end

  test "clear ends an open interval and never attributes new-epoch audio to old audio", %{
    state: state
  } do
    state = play(enqueue(state, 1_000), 0..12)
    cleared = Media.clear(state, 1)
    assert cleared.media.playback_diagnostics.last_gap.cause == :cleared
    assert cleared.media.playback_diagnostics.last_gap.peak_after == nil
    assert cleared.media.playback_diagnostics.last_gap.epoch == 0
    restarted = play(enqueue(cleared, 2_000), 13..24)
    assert restarted.media.playback_diagnostics.count == 1
    assert restarted.media.playback_diagnostics.last_gap.cause == :cleared
    refute restarted.media.playback_diagnostics.gap
  end

  test "closed and clear summaries preserve unknown after-level; history stays constant size" do
    final =
      Enum.reduce(0..999, %PlaybackDiagnostics{}, fn index, acc ->
        now = index * 30_000
        {acc, _} = PlaybackDiagnostics.observe(acc, <<1, 0>>, true, now, index)
        {acc, _} = PlaybackDiagnostics.observe(acc, <<0, 0>>, false, now + 10_000, index)
        {acc, event} = PlaybackDiagnostics.finish(acc, :closed, now + 20_000)
        assert event.peak_after == nil
        assert event.duration_us == 10_000
        acc
      end)

    assert final.count == 1_000
    assert final.gap == nil
    assert final.last_gap.gap_id == 1_000
    assert byte_size(:erlang.term_to_binary(final)) < 1_024
  end

  test "signaling forwards numeric observations and no arbitrary event data" do
    event = %Event{
      type: :audio_observed,
      source: :channel,
      payload: %{
        cause: :source_resumed,
        boundary: :browser_pcm,
        gap_id: 1,
        epoch: 0,
        duration_us: 210_000,
        inserted_silence_us: 210_000,
        peak_before: 1_000,
        peak_after: 2_000,
        source_returned_at_us: 100_000,
        source_unavailable_us: 90_000,
        recovery_wait_us: 120_000,
        recovery_release_reason: :deadline,
        raw_pcm: <<1, 2>>
      }
    }

    assert {:push, {:text, encoded}, %{}} = Signaling.handle_info({:parlora_event, event}, %{})
    payload = Jason.decode!(encoded)["payload"]
    assert payload["cause"] == "source_resumed"
    assert payload["duration_us"] == 210_000
    assert payload["peak_after"] == 2_000
    assert payload["source_returned_at_us"] == 100_000
    assert payload["source_unavailable_us"] == 90_000
    assert payload["recovery_wait_us"] == 120_000
    assert payload["recovery_release_reason"] == "deadline"
    refute Map.has_key?(payload, "raw_pcm")
  end

  test "render telemetry records the learned and latched targets without audio", %{state: state} do
    handler = make_ref()
    owner = self()
    id = "adaptive-target-#{System.unique_integer([:positive])}"
    state = put_in(state.init.session_id, id)

    :ok =
      :telemetry.attach(
        handler,
        [:parlora, :audio, :playout],
        &__MODULE__.send_render_metrics/4,
        {owner, id}
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    target = %{Target.new(120, 200) | target_ms: 200}
    playout = %{Parlora.Playout.new(120, 9_600, playback_buffering: :adaptive) | target: target}
    state = put_in(state.media.playout, playout) |> enqueue(1_000)
    {_packet, next} = Media.output(state, 0)
    assert_receive {:render_metrics, metrics}
    assert metrics.playback_target_ms == 200
    assert metrics.playback_buffer_ms == 200
    assert metrics.recovery_cap_us == 120_000
    assert metrics.queue_bytes == 5_760
    assert metrics.source_bytes == 0
    assert metrics.silence_bytes == 480
    assert next.media.playout.target.target_ms == 200
    assert Enum.all?(metrics, fn {_, value} -> is_number(value) end)
  end

  test "quiet refill reports available source and bounded waiting, without a false shortage", %{
    state: state
  } do
    playout = %{
      Parlora.Playout.new(120, 9_600, playback_buffering: :adaptive)
      | playing?: true,
        buffer_ms: 200
    }

    playout = %{
      playout
      | target: %{
          playout.target
          | target_ms: 200,
            group: %{at: 0, duration: 20_000, identity: {"probe", 0}}
        }
    }

    state = put_in(state.media.playout, playout)
    played = state |> enqueue(4_000, 8) |> enqueue(32, 12) |> play(0..11)
    held = play(played, 12..17)
    open = PlaybackDiagnostics.snapshot(held.media.playback_diagnostics, 180_000).open_gap
    assert open.cause == :quiet_refill
    assert open.source_unavailable_us == 0
    assert open.recovery_wait_us == 60_000
    assert open.recovery_target_us == 60_000
    assert open.peak_before == 32
    assert held.media.outbound.bytes == 80 * 48
    assert held.media.rendered_source_bytes == 120 * 48
    resumed = play(held, 18..18)
    summary = resumed.media.playback_diagnostics.last_gap
    assert summary.peak_after == 32
    assert summary.source_unavailable_us == 0
    assert summary.recovery_wait_us == 60_000
    assert summary.recovery_release_reason == :quiet_refill
    assert resumed.media.playout.quiet.count == 1

    assert_receive {:parlora_event,
                    %Event{
                      type: :audio_observed,
                      payload: %{cause: :quiet_refill, source_unavailable_us: 0}
                    }}
  end

  def send_render_metrics(_event, metrics, meta, {owner, id}) do
    if meta.session_id == id, do: send(owner, {:render_metrics, metrics})
  end

  defp enqueue(state, sample, frames \\ 12) do
    queue =
      Enum.reduce(0..(frames - 1), state.media.outbound, fn sequence, queue ->
        frame = AudioFrame.pcm(:binary.copy(<<sample::little-signed-16>>, 240), "probe", sequence)
        {:ok, next} = AudioQueue.push(queue, frame)
        next
      end)

    Media.update(state, %{outbound: queue})
  end

  defp play(state, ticks) do
    Enum.reduce(ticks, state, fn tick, acc ->
      {_packet, next} = Media.output(acc, tick * 10_000)
      next
    end)
  end
end
