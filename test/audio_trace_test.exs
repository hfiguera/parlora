defmodule Parlora.AudioTraceTest do
  use ExUnit.Case, async: true
  alias Parlora.{AdapterInit, AudioFormat, Event, Limits}
  alias Parlora.Channels.Browser.Signaling
  alias Parlora.Provider.OutputBuffer
  alias Parlora.Providers.OpenAI
  alias Parlora.Providers.OpenAI.AudioTrace

  test "bounded trace retains the last burst and drain amounts without PCM" do
    trace =
      Enum.reduce(1..100, AudioTrace.new(0), fn i, t ->
        t
        |> AudioTrace.record(:received, 4_800, 0, i * 100_000)
        |> AudioTrace.record(:read, 4_800, 0, i * 100_000 + 1)
      end)

    trace =
      Enum.reduce(0..5, trace, fn i, t ->
        AudioTrace.record(t, :received, 4_800, i * 4_800, 11_000_000 + i)
      end)

    report = AudioTrace.report(trace, 11_000_006)
    assert Enum.count_until(report.events, 65) == 64
    assert report.events_seen == 206 and report.truncated
    burst = Enum.filter(report.events, &(&1.at_us >= 11_000_000))
    assert Enum.map(burst, & &1.queue_bytes) == [0, 4_800, 9_600, 14_400, 19_200, 24_000]
    assert List.last(burst).at_us - hd(burst).at_us == 5
  end

  test "recoverable receive diagnostics reach browser before replacement without arbitrary error data" do
    init = %AdapterInit{
      session_id: "trace",
      generation: 0,
      adapter_id: "trace",
      event_sink: self(),
      audio_format: %AudioFormat{},
      limits: %Limits{}
    }

    {:ok, state, _} = OpenAI.init({init, [api_key: "never-display"], %{}})
    now = System.monotonic_time(:microsecond)
    old = now - 800_000
    {:ok, {queue, _}} = OutputBuffer.push(state.inbound, :binary.copy(<<0>>, 4_800), init, 0, old)
    trace = AudioTrace.new(old) |> AudioTrace.record(:received, 4_800, 0, old)
    state = %{state | status: :ready, inbound: queue, audio_trace: trace}

    assert {:reply, {:ok, []}, recovering} =
             OpenAI.handle_call({:read, 960}, nil, state)

    assert recovering.status == :recovering
    assert_receive {:parlora_event, %Event{type: :audio_discontinuity} = event}
    event = %{event | payload: Map.put(event.payload, :private, "never-display")}
    assert {:push, {:text, json}, %{}} = Signaling.handle_info({:parlora_event, event}, %{})
    payload = Jason.decode!(json)["payload"]
    assert payload["queue_bytes"] == 4_800
    assert payload["dropped_bytes"] == 4_800
    assert payload["incoming_bytes"] == 0
    assert payload["capacity_bytes"] == 33_600
    assert payload["oldest_age_us"] >= 800_000
    assert [%{"kind" => "received", "bytes" => 4_800}] = payload["audio_trace"]["events"]
    refute json =~ "never-display"
    assert_receive {:parlora_event, %Event{type: :output_recovery_requested}}
    refute_received {:parlora_event, %Event{type: :failed}}
  end
end
