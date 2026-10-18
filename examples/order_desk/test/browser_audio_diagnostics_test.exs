defmodule OrderDesk.BrowserAudioDiagnosticsTest do
  use ExUnit.Case
  alias OrderDesk.BrowserAudioDiagnostics, as: Diagnostics
  alias Parlora.Channels.Browser
  import Plug.Test
  import Plug.Conn

  setup do
    start_supervised!({Diagnostics, max_events: 3})
    Application.put_env(:order_desk, :browser_offline, true)
    on_exit(fn -> Application.delete_env(:order_desk, :browser_offline) end)
    :ok
  end

  test "trace is session-filtered, numeric, capped, and retained after session death" do
    {:ok, session} = OrderDesk.BrowserGate.start_session({Browser, signaling: self()}, "owner")
    %{session_id: id} = Parlora.snapshot(session)
    meta = %{session_id: id}

    for i <- 1..5 do
      :telemetry.execute(
        [:parlora, :provider, :audio_received],
        %{
          at_us: System.monotonic_time(:microsecond),
          bytes: i * 480,
          queue_bytes: 0,
          raw_pcm: "private",
          credentials: "secret"
        },
        meta
      )
    end

    :telemetry.execute(
      [:parlora, :audio, :tick],
      %{late_us: 100},
      Map.put(meta, :direction, :input)
    )

    :telemetry.execute([:parlora, :provider, :audio_received], %{bytes: 99}, %{
      session_id: "other"
    })

    assert %{calls: []} = Diagnostics.snapshot("other-owner")
    assert %{calls: []} = Diagnostics.snapshot("owner", true, "other-id")
    %{calls: [call]} = Diagnostics.snapshot("owner")
    assert call.events_seen == 5
    assert call.truncated
    assert length(call.events) == 3
    assert Enum.map(call.events, & &1.metrics.bytes) == [480, 960, 1440]
    refute Jason.encode!(call) =~ "private"
    refute Jason.encode!(call) =~ "secret"
    %{calls: [summary]} = Diagnostics.snapshot("owner", false)
    assert summary.events == []
    assert summary.events_seen == 5
    close_session(session)
    await_closed("owner", System.monotonic_time(:millisecond) + 5_000)
    %{calls: [closed]} = Diagnostics.snapshot("owner")
    assert closed.closed
    assert closed.events == call.events
    :telemetry.execute([:parlora, :provider, :audio_received], %{bytes: 999}, meta)
    assert Diagnostics.snapshot("owner").calls == [closed]
  end

  test "HTTP reports use the browser cookie and omit traces from summary polling" do
    response = route(conn(:get, "/api/orders"))
    actor = get_session(response, :actor)
    [{cookie_name, cookie}] = Map.to_list(response.resp_cookies)
    {:ok, session} = OrderDesk.BrowserGate.start_session({Browser, signaling: self()}, actor)
    %{session_id: id} = Parlora.snapshot(session)
    :telemetry.execute([:parlora, :provider, :audio_received], %{bytes: 480}, %{session_id: id})

    own =
      conn(:get, "/api/audio-diagnostics?summary=1&session_id=#{id}")
      |> put_req_cookie(cookie_name, cookie.value)
      |> route()

    assert own.status == 200

    assert %{"calls" => [%{"session_id" => ^id, "events" => [], "events_seen" => 1}]} =
             Jason.decode!(own.resp_body)

    stranger = route(conn(:get, "/api/audio-diagnostics?session_id=#{id}"))
    assert %{"calls" => []} = Jason.decode!(stranger.resp_body)
    close_session(session)
    await_closed(actor, System.monotonic_time(:millisecond) + 5_000)
  end

  test "playout trace retains numeric source levels and positions but rejects audio" do
    {:ok, session} = OrderDesk.BrowserGate.start_session({Browser, signaling: self()}, "owner")
    %{session_id: id} = Parlora.snapshot(session)

    :telemetry.execute(
      [:parlora, :audio, :playout],
      %{
        source_bytes: 240,
        source_peak: 4_096,
        quiet_refill: 1,
        quiet_refills: 2,
        source_position_bytes: 960,
        epoch: 2,
        raw_pcm: <<1, 2, 3>>
      },
      %{session_id: id}
    )

    # Allowlisted values must still be numeric.
    :telemetry.execute(
      [:parlora, :audio, :playout],
      %{source_peak: "private", source_position_bytes: <<1, 2, 3>>, epoch: "private"},
      %{session_id: id}
    )

    %{calls: [%{events: [first, second]}]} = Diagnostics.snapshot("owner")

    assert first.metrics == %{
             source_bytes: 240,
             source_peak: 4_096,
             quiet_refill: 1,
             quiet_refills: 2,
             source_position_bytes: 960,
             epoch: 2
           }

    assert second.metrics == %{}
    close_session(session)
  end

  test "quiet holds and speech continuation retain only known gap labels and numbers" do
    {:ok, session} = OrderDesk.BrowserGate.start_session({Browser, signaling: self()}, "owner")
    %{session_id: id} = Parlora.snapshot(session)

    for reason <- [:quiet_refill, :speech_continuation] do
      send(
        Diagnostics,
        {:parlora_event,
         %{
           session_id: id,
           type: :audio_observed,
           payload: %{
             cause: :quiet_refill,
             boundary: :browser_pcm,
             recovery_release_reason: reason,
             source_unavailable_us: 0,
             recovery_wait_us: 60_000,
             raw_pcm: "private"
           }
         }}
      )
    end

    %{calls: [%{gaps: gaps}]} = Diagnostics.snapshot("owner")
    assert length(gaps) == 2
    assert Enum.map(gaps, & &1.recovery_release_reason) == [:quiet_refill, :speech_continuation]
    assert Enum.all?(gaps, &(&1.cause == :quiet_refill and &1.source_unavailable_us == 0))
    refute Jason.encode!(gaps) =~ "private"
    close_session(session)
  end

  # Close admits asynchronous teardown. Do not leave a session or its admission
  # slot behind for another test after this collector stops.
  defp close_session(session) do
    reference = Process.monitor(session)
    :ok = Parlora.close(session)
    assert_receive {:DOWN, ^reference, :process, ^session, _reason}, 5_000
    await_gate_empty(System.monotonic_time(:millisecond) + 1_000)
  end

  defp await_gate_empty(deadline) do
    if OrderDesk.BrowserGate.count() > 0 do
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(5)
      await_gate_empty(deadline)
    end
  end

  defp route(conn), do: OrderDesk.BrowserServer.call(conn, OrderDesk.BrowserServer.init([]))

  defp await_closed(actor, deadline) do
    case Diagnostics.snapshot(actor, false) do
      %{calls: [%{closed: true}]} ->
        :ok

      _ ->
        assert System.monotonic_time(:millisecond) < deadline
        Process.sleep(5)
        await_closed(actor, deadline)
    end
  end
end
