Code.require_file("../validation/playout-hardening-20261003/timeline.exs", __DIR__)

defmodule Parlora.PlayoutTimelineTest do
  use ExUnit.Case, async: true
  alias Parlora.Validation.PlayoutTimeline

  @tag :tmp_dir
  test "an opt-in timeline isolates sessions and bounds retention without losing truncation evidence",
       %{tmp_dir: directory} do
    init = %{session_id: Parlora.ID.new()}
    trace = PlayoutTimeline.open(directory, init)

    on_exit(fn ->
      :telemetry.detach(trace.handler)
      File.rm_rf!(directory)
    end)

    tick = %{at_us: 1, work_us: 2, late_us: 0, delay_ms: 10, pending_frames: 0, blocked: 0}

    :telemetry.execute([:parlora, :audio, :tick], tick, %{
      session_id: "other",
      direction: :output
    })

    assert :ets.lookup_element(trace.table, :count, 2) == 0
    PlayoutTimeline.mark(trace, :run)

    :telemetry.execute([:parlora, :audio, :tick], %{tick | at_us: 2, work_us: 3}, %{
      session_id: init.session_id,
      direction: :output
    })

    assert :ets.lookup_element(trace.table, :count, 2) == 2
    :ets.insert(trace.table, {:count, 131_072})

    :telemetry.execute(
      [:parlora, :audio, :playout],
      %{at_us: 3, source_bytes: 480, silence_bytes: 0, padding_bytes: 0, queue_bytes: 0},
      %{session_id: init.session_id, channel: :browser, epoch: 0}
    )

    assert :ok = PlayoutTimeline.close(trace)
    report = File.read!(trace.path) |> JSON.decode!()
    assert report["seen"] == 131_073
    assert report["truncated"]
    assert Enum.map(report["rows"], & &1["kind"]) == ["run", "tick"]
    assert :ets.info(trace.table) == :undefined
  end

  test "disabled tracing allocates nothing" do
    assert PlayoutTimeline.open(nil, %{session_id: "disabled"}) == nil
    assert PlayoutTimeline.mark(nil, :run) == :ok
    assert PlayoutTimeline.close(nil) == :ok
  end
end
