defmodule ParloraObserverTest do
  use ExUnit.Case, async: false

  test "a real offline session completes without an observability service" do
    id = ParloraObserver.Demo.run()
    state = :sys.get_state(ParloraObserver.Traces)
    refute Enum.any?(state.spans, fn {_key, entry} -> entry.session == id end)
    assert TelemetryMetricsPrometheus.Core.scrape() =~ "parlora_session_stop_count"
  end

  test "metrics endpoint is available without Docker and contains no session labels" do
    token = Parlora.Telemetry.start(:startup, %{session_id: "not-a-label"})
    :ok = Parlora.Telemetry.stop(token, :ready)
    response = Plug.Test.conn(:get, "/metrics") |> ParloraObserver.Metrics.call([])
    assert response.status == 200
    assert response.resp_body =~ "parlora_startup_stop"
    refute response.resp_body =~ "not-a-label"
  end
end

defmodule ParloraObserverBufferTest do
  use ExUnit.Case, async: false

  test "a killed trace worker can restart without leaving a stale handler" do
    old = Process.whereis(ParloraObserver.Traces)
    ref = Process.monitor(old)
    Process.exit(old, :kill)
    assert_receive {:DOWN, ^ref, :process, ^old, :killed}
    new = await_restart(old, System.monotonic_time(:millisecond) + 5_000)
    assert Process.alive?(new)
    _ready = :sys.get_state(new)
    token = Parlora.Telemetry.start(:policy, %{session_id: "restart-test"})
    assert Map.has_key?(:sys.get_state(new).spans, token.metadata.operation_id)
    Parlora.Telemetry.stop(token, :ok)
    assert :sys.get_state(new).spans == %{}
  end

  defp await_restart(old, deadline) do
    case Process.whereis(ParloraObserver.Traces) do
      pid when is_pid(pid) and pid != old ->
        pid

      _not_ready ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: flunk("Trace bridge did not restart")

        receive do
        after
          10 -> await_restart(old, deadline)
        end
    end
  end

  test "a suspended trace consumer cannot grow its admitted queue without bound" do
    pid = Process.whereis(ParloraObserver.Traces)
    credits = :sys.get_state(pid).credits
    :sys.suspend(pid)
    on_exit(fn -> if Process.alive?(pid), do: :sys.resume(pid) end)
    tokens = for _ <- 1..300, do: Parlora.Telemetry.start(:policy, %{session_id: "buffer-test"})
    assert :atomics.get(credits, 1) == 256
    assert :atomics.get(credits, 2) >= 44
    :sys.resume(pid)
    state = :sys.get_state(pid)
    assert :atomics.get(credits, 1) == 0
    assert map_size(state.spans) <= 256
    Enum.each(tokens, &Parlora.Telemetry.stop(&1, :ok))
    # Expiry also releases spans when stop observations were dropped during pressure.
    :sys.replace_state(pid, fn state ->
      %{state | spans: Map.new(state.spans, fn {id, entry} -> {id, %{entry | expires_at: 0}} end)}
    end)

    send(pid, :expire)
    assert :sys.get_state(pid).spans == %{}
  end
end

defmodule ParloraObserverUnitsTest do
  use ExUnit.Case, async: false

  test "exported duration units and buckets are seconds, not native units or microseconds" do
    token = Parlora.Telemetry.start(:backend, %{session_id: "units-test"})

    :telemetry.execute(
      [:parlora, :backend, :stop],
      %{
        duration: System.convert_time_unit(200, :millisecond, :native),
        count: 1,
        monotonic_time: System.monotonic_time()
      },
      Map.put(token.metadata, :outcome, :rejected)
    )

    :telemetry.execute(
      [:parlora, :provider, :audio_received],
      %{queue_duration_us: 120_000, queue_bytes: 5760, dropped_bytes: 0},
      %{}
    )

    :telemetry.execute([:parlora, :audio, :tick], %{late_us: 25_000}, %{direction: :calibration})

    :telemetry.execute([:parlora, :audio, :playout], %{playback_target_ms: 120}, %{
      channel: :calibration
    })

    body = TelemetryMetricsPrometheus.Core.scrape()
    assert body =~ ~s(parlora_backend_stop_duration_seconds_sum{outcome="rejected"} 0.2)
    assert body =~ ~s(parlora_backend_stop_duration_seconds_bucket{outcome="rejected",le="0.1"} 0)

    assert body =~
             ~s(parlora_backend_stop_duration_seconds_bucket{outcome="rejected",le="0.25"} 1)

    assert body =~ "parlora_provider_audio_received_queue_duration_seconds_sum 0.12"

    [_, late] =
      Regex.run(~r/parlora_audio_tick_late_seconds_sum\{direction="calibration"\} ([^\n]+)/, body)

    assert_in_delta String.to_float(late), 0.025, 1.0e-12
    assert body =~ ~s(parlora_audio_playout_target_seconds_sum{channel="calibration"} 0.12)
    refute body =~ "late_us"
    refute body =~ "queue_duration_us"
  end

  test "events without a stage are retained and grouping does not require IDs" do
    Parlora.Telemetry.event(%Parlora.Event{
      session_id: "not-a-metric-label",
      source: :session,
      type: :request_uncertain,
      payload: %{reason: :execution_deadline}
    })

    body = TelemetryMetricsPrometheus.Core.scrape()
    assert body =~ ~s(stage="none",type="request_uncertain")
    refute body =~ "not-a-metric-label"
  end
end
