# Validation-only capture of generated OUTPUT PCM, before device conversion.
# No microphone bytes are traced. Existing probe controls session duration/cleanup.
defmodule OutputCapture do
  def arm(_name, _measurements, _metadata, recorder) do
    unless Process.get(:output_capture_armed) do
      :erlang.trace(self(), true, [:call, :monotonic_timestamp, {:tracer, recorder}])
      Process.put(:output_capture_armed, true)
    end
  end

  def collect(rows \\ [], count \\ 0) do
    receive do
      {:trace_ts, pid, :return_from, {Parlora.Playout, :take, 4}, {pcm, _queue, state}, at}
      when count < 6_000 ->
        row = %{
          pid: inspect(pid),
          at_us: System.convert_time_unit(at, :native, :microsecond),
          source_bytes: state.source_bytes,
          silence_bytes: state.silence_bytes,
          starvations: state.starvations,
          pcm: Base.encode64(pcm)
        }

        collect([row | rows], count + 1)

      {:trace_ts, _, :return_from, _, _, _} ->
        collect(rows, count)

      {:finish, caller} ->
        send(caller, {:captured, Enum.reverse(rows), count})

      _other ->
        collect(rows, count)
    end
  end
end

{:module, Parlora.Playout} = Code.ensure_loaded(Parlora.Playout)
recorder = spawn_link(fn -> OutputCapture.collect() end)

:erlang.trace_pattern(
  {Parlora.Playout, :take, 4},
  [{:_, [], [{:message, false}, {:return_trace}]}],
  [:local]
)

:ok =
  :telemetry.attach(
    "output-capture",
    [:parlora, :audio, :playout],
    &OutputCapture.arm/4,
    recorder
  )

try do
  Code.require_file("../pcm-overflow/trace.exs", __DIR__)
after
  :telemetry.detach("output-capture")
  :erlang.trace_pattern({Parlora.Playout, :take, 4}, false, [:local])
  send(recorder, {:finish, self()})

  receive do
    {:captured, rows, count} ->
      File.write!(
        System.fetch_env!("PARLORA_CAPTURE_OUTPUT"),
        Jason.encode!(%{frames: rows, bound: 6000, at_bound: count == 6000})
      )
  after
    2000 -> raise "Capture drain timed out"
  end
end
