defmodule Parlora.RecordedRecoveryTest do
  use ExUnit.Case, async: true
  alias Parlora.{AdapterInit, AudioFormat, AudioFrame, AudioQueue, Limits}
  alias Parlora.Channels.Browser.Media

  test "recorded full-cushion gaps resume earlier without losing source samples" do
    for id <- [3, 14] do
      report =
        File.read!("validation/browser-retry-20260921/audio-gap-#{id}.json") |> Jason.decode!()

      old = replay(report, :historical)
      fixed = replay(report, :current)
      assert old.gap.duration_us == report["gap"]["measurements"]["duration_us"]
      assert old.gap.inserted_silence_us == report["gap"]["measurements"]["inserted_silence_us"]
      assert fixed.gap.source_unavailable_us == old.gap.source_unavailable_us
      assert fixed.gap.recovery_wait_us <= 40_000
      assert fixed.gap.inserted_silence_us == if(id == 3, do: 60_000, else: 90_000)
      assert fixed.gap.duration_us < old.gap.duration_us
      assert fixed.gap.recovery_release_reason == :queue_ready
      assert fixed.played == old.played
      assert fixed.played == fixed.received
    end
  end

  test "a short shortage resumes from one batch without waiting for the second" do
    report = File.read!("validation/browser-cushion-20260921/gap-2.json") |> Jason.decode!()
    fixed = replay(report, :current)
    assert report["gap"]["measurements"]["inserted_silence_us"] == 120_000
    assert fixed.gap.inserted_silence_us == 30_000

    assert fixed.gap.source_unavailable_us ==
             report["gap"]["measurements"]["source_unavailable_us"]

    assert fixed.gap.recovery_wait_us == 9_946
    assert fixed.gap.recovery_release_reason == :queue_ready
    assert fixed.gap.resume_queue_bytes == 3_840
    assert fixed.played == fixed.received
  end

  test "recorded short shortages avoid the fixed hold and threshold jump" do
    for {id, silence} <- [{4, 20_000}, {9, 30_000}, {14, 90_000}] do
      report =
        File.read!("validation/browser-recovery-threshold-20260921/gap-#{id}.json")
        |> Jason.decode!()

      fixed = replay(report, :current)
      recorded = report["gap"]["measurements"]
      assert fixed.gap.inserted_silence_us == silence
      assert fixed.gap.inserted_silence_us < recorded["inserted_silence_us"]
      assert fixed.gap.source_unavailable_us == recorded["source_unavailable_us"]
      assert fixed.gap.recovery_wait_us < recorded["recovery_wait_us"]
      assert fixed.played == fixed.received
    end
  end

  test "latest live gap releases queued speech without the half-shortage hold" do
    fixture =
      File.read!("validation/browser-gap-20260921/call-1748/trace-excerpts.json")
      |> Jason.decode!()

    for report <- fixture["reports"] do
      fixed = replay(report, :current)

      expected =
        %{11 => 30_000, 12 => 20_000, 19 => 40_000}[report["gap"]["measurements"]["gap_id"]]

      assert fixed.gap.inserted_silence_us == expected
      assert fixed.played == fixed.received
      assert fixed.gap.recovery_release_reason == :queue_ready
    end
  end

  test "recorded hiccups drain promptly once the current shortage cushion is ready" do
    fixture =
      File.read!("validation/browser-gap-20260921/call-1826/trace-excerpts.json")
      |> Jason.decode!()

    for report <- fixture["gaps"], id = report["gap"]["report_index"], id in [6, 8, 9] do
      fixed = replay(report, :current)
      assert fixed.gap.inserted_silence_us == %{6 => 70_000, 8 => 30_000, 9 => 50_000}[id]
      assert fixed.gap.recovery_wait_us <= 11_000
      assert fixed.gap.recovery_release_reason == :queue_ready
      assert fixed.played == fixed.received
    end
  end

  defp replay(report, policy) do
    gap = report["gap"]["measurements"]
    start = gap["started_at_us"]

    init = %AdapterInit{
      session_id: "recorded-recovery",
      adapter_id: "browser",
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

    playout = %{media.playout | playing?: true}

    playout = replay_policy(playout, policy)
    state = %{init: init, media: %{media | playout: playout}}
    state = enqueue(state, 480)
    {_packet, state} = Media.output(state, -10_000)

    events =
      Enum.filter(report["events"], fn e ->
        e["kind"] in ["frame", "playout"] and e["measurements"]["at_us"] >= start and
          e["measurements"]["at_us"] <= gap["at_us"]
      end)

    # The recording can end after gap completion, before its playout event.
    events =
      if Enum.any?(
           events,
           &(&1["kind"] == "playout" and &1["measurements"]["at_us"] == gap["at_us"])
         ) do
        events
      else
        events ++ [%{"kind" => "playout", "measurements" => %{"at_us" => gap["at_us"]}}]
      end

    try do
      {state, received} =
        Enum.reduce(events, {state, 480}, fn e, {state, received} ->
          m = e["measurements"]

          if e["kind"] == "frame" do
            {enqueue(state, m["bytes"]), received + m["bytes"]}
          else
            {elem(Media.output(state, m["at_us"] - start), 1), received}
          end
        end)

      observed = state.media.playback_diagnostics.last_gap

      final =
        Enum.reduce(1..50, state, fn tick, state ->
          elem(Media.output(state, gap["at_us"] - start + tick * 10_000), 1)
        end)

      %{gap: observed, played: final.media.playout.source_bytes, received: received}
    after
      Media.close(media)
    end
  end

  defp replay_policy(playout, :historical), do: %{playout | recovery_bytes: nil}
  defp replay_policy(playout, :current), do: playout

  defp enqueue(state, bytes) do
    frame = AudioFrame.pcm(:binary.copy(<<6000::little-signed-16>>, div(bytes, 2)), "replay", 0)
    {:ok, queue} = AudioQueue.push(state.media.outbound, frame)
    Media.update(state, %{outbound: queue})
  end
end
