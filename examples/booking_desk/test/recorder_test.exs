defmodule BookingDesk.RecorderTest do
  use ExUnit.Case, async: false
  alias BookingDesk.{Recorder, ReplayChannel}
  alias Parlora.{AdapterInit, AudioFormat, AudioFrame, Limits}

  setup do
    path = Path.join(System.tmp_dir!(), "booking-recording-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(path) end)
    {:ok, recorder} = Recorder.start_link(directory: path)
    %{recorder: recorder, path: path}
  end

  test "separate audio tracks retain offsets, count credits, and omit credentials", %{
    recorder: recorder,
    path: path
  } do
    observer = Recorder.observer(recorder)
    Parlora.AudioObserver.send_audio(observer, :input, <<1, 0, 2, 0>>)
    Parlora.AudioObserver.send_audio(observer, :output, <<3, 0, 4, 0>>)
    report = Recorder.finish(recorder, %{fictional: true})
    assert report.audio.dropped_packets == 0
    assert length(report.audio.chunks) == 2
    assert File.read!(Path.join(path, "input.pcm")) == <<1, 0, 2, 0>>
    assert File.read!(Path.join(path, "output.pcm")) == <<3, 0, 4, 0>>
    refute File.read!(Path.join(path, "session.json")) =~ "api_key"
    assert :atomics.get(observer.credits, 1) == 0
    GenServer.stop(recorder)
  end

  test "audio budget covers the 210 second replay deadline and remains bounded", %{
    recorder: recorder
  } do
    observer = Recorder.observer(recorder)
    # Exercise the boundary without generating minutes of synthetic packets.
    :sys.replace_state(recorder, fn s -> put_in(s.sizes.input, 24_000 * 2 * 180) end)
    Parlora.AudioObserver.send_audio(observer, :input, <<1, 0>>)
    state = :sys.get_state(recorder)
    assert state.sizes.input == 24_000 * 2 * 180 + 2
    assert :atomics.get(observer.credits, 2) == 0
    :sys.replace_state(recorder, fn s -> put_in(s.sizes.input, 24_000 * 2 * 240) end)
    Parlora.AudioObserver.send_audio(observer, :input, <<1, 0>>)
    _ = :sys.get_state(recorder)
    assert :atomics.get(observer.credits, 2) == 1
    GenServer.stop(recorder)
  end

  test "interruption clears old software audio before it can enter the recorded playout", %{
    recorder: recorder,
    path: path
  } do
    init = %AdapterInit{
      session_id: "test",
      adapter_id: "test",
      generation: 0,
      event_sink: self(),
      audio_format: %AudioFormat{},
      limits: %Limits{}
    }

    {:ok, channel} =
      ReplayChannel.start_link(init, owner: self(), observer: Recorder.observer(recorder))

    assert_receive {:parlora_event, %{type: :ready}}
    pcm = :binary.copy(<<0, 16>>, 240)
    frame = AudioFrame.pcm(pcm, "old", 0, playback_epoch: 0)
    assert :ok = ReplayChannel.write_audio(channel, frame)
    assert :ok = ReplayChannel.control(channel, "interrupt", {:clear_output, 1})
    assert {:error, _} = ReplayChannel.write_audio(channel, frame)
    assert :ok = ReplayChannel.close(channel, "close", :normal)
    report = Recorder.finish(recorder, %{})
    assert report.audio.dropped_packets == 0
    output = File.read!(Path.join(path, "output.pcm"))
    assert Enum.all?(for(<<sample::signed-little-16 <- output>>, do: sample), &(&1 == 0))
    GenServer.stop(channel)
    GenServer.stop(recorder)
  end

  test "microphone playback traffic cannot hide later patient lookup diagnostics", %{
    recorder: recorder,
    path: path
  } do
    at = System.monotonic_time(:microsecond)

    event = %Parlora.Event{
      id: "playback",
      session_id: "test",
      source: :channel,
      adapter_id: "local",
      generation: 0,
      type: :playback_observed,
      observed_at_us: at,
      payload: %{stage: :queued}
    }

    for i <- 0..12_999 do
      Recorder.event(recorder, %{
        event
        | observed_at_us: at + i * 1_000,
          payload: %{stage: if(rem(i, 2) == 0, do: :queued, else: :handed_off)}
      })
    end

    observer = Recorder.observer(recorder)
    Recorder.telemetry([:parlora, :runtime, :event], %{count: 1}, %{}, observer)

    Recorder.event(recorder, %{
      event
      | type: :transcript_delta,
        observed_at_us: at + 45_000_000,
        payload: %{speaker: :user, delta: "Jamie Rivera, March 12, 1990."}
    })

    Recorder.telemetry(
      [:booking_desk, :extraction, :stop],
      %{duration_us: 1_000, attempt: 2},
      %{field: :identity, outcome: :error, reason: :invalid_extraction},
      observer
    )

    report = Recorder.finish(recorder, %{})

    assert length(report.events) < 40
    assert report.event_log.sampled_playback_events > 12_000
    assert report.event_log.dropped_events == 0
    assert Enum.any?(report.events, &(&1.name == :transcript_delta))

    assert Enum.any?(
             report.events,
             &(&1.name == "booking_desk.extraction.stop" and
                 &1.data.reason == :invalid_extraction and &1.data.field == :identity)
           )

    assert :atomics.get(observer.credits, 1) == 0
    assert File.read!(Path.join(path, "events.jsonl")) =~ "Jamie Rivera"
    GenServer.stop(recorder)
  end

  test "non-ASCII captions survive append-only recording", %{recorder: recorder, path: path} do
    event = %Parlora.Event{
      id: "unicode",
      session_id: "test",
      source: :provider,
      adapter_id: "p",
      generation: 0,
      type: :transcript_delta,
      observed_at_us: System.monotonic_time(:microsecond),
      payload: %{speaker: :assistant, delta: "Thursday — sí, voilà."}
    }

    Recorder.event(recorder, event)
    Recorder.finish(recorder, %{})
    assert File.read!(Path.join(path, "events.jsonl")) =~ "Thursday — sí, voilà."
    GenServer.stop(recorder)
  end

  test "failure diagnostics retain local codes without arbitrary error text or details", %{
    recorder: recorder,
    path: path
  } do
    event = %Parlora.Event{
      id: "failure",
      session_id: "test",
      source: :provider,
      adapter_id: "p",
      generation: 0,
      type: :failed,
      observed_at_us: System.monotonic_time(:microsecond),
      payload: %{
        error:
          Parlora.Error.new(:adapter_failed, "private error message", %{
            reason: :response_timeout,
            api_key: "private credential"
          })
      }
    }

    Recorder.event(recorder, event)

    Recorder.event(recorder, %{
      event
      | payload: %{error: %{event.payload.error | details: %{reason: "private reason"}}}
    })

    report = Recorder.finish(recorder, %{})

    assert Enum.at(report.events, 0).data == %{
             error_code: :adapter_failed,
             error_reason: :response_timeout
           }

    assert Enum.at(report.events, 1).data == %{error_code: :adapter_failed}
    refute File.read!(Path.join(path, "session.json")) =~ "private"
    GenServer.stop(recorder)
  end

  test "policy rejections retain safe diagnostics instead of empty event data", %{
    recorder: recorder,
    path: path
  } do
    for type <- [:policy_rejected, :policy_failed, :context_rejected] do
      Recorder.event(recorder, %Parlora.Event{
        id: Atom.to_string(type),
        session_id: "test",
        source: :session,
        adapter_id: "session",
        generation: 0,
        type: type,
        observed_at_us: System.monotonic_time(:microsecond),
        payload: %{
          error:
            Parlora.Error.new(
              :invalid_argument,
              "Clarification requires a question and an optional 1–128 byte key",
              %{private: "private credential"}
            )
        }
      })
    end

    report = Recorder.finish(recorder, %{})
    assert length(report.events) == 3

    assert Enum.all?(report.events, fn event ->
             event.data == %{
               error_code: :invalid_argument,
               error_reason: :invalid_clarification
             }
           end)

    refute File.read!(Path.join(path, "events.jsonl")) =~ "private"
    GenServer.stop(recorder)
  end
end
