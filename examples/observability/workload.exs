Code.require_file("session.exs", __DIR__)

# Real offline sessions with controlled backend delays and outcomes. No fabricated
# telemetry: raw observations are retained locally to check exported aggregates.
receiver = self()
handler = {__MODULE__, make_ref()}

:telemetry.attach_many(
  handler,
  Parlora.Telemetry.events() ++
    [
      [:parlora, :provider, :audio_received],
      [:parlora, :provider, :audio_read],
      [:parlora, :audio, :tick]
    ],
  fn name, values, metadata, pid ->
    send(pid, {:workload_observation, name, values, metadata})
  end,
  receiver
)

# Exercise the actual output buffer with known PCM durations, not synthetic
# telemetry. These are isolated queue probes, not model or audible audio tests.
queue_probe = fn milliseconds ->
  alias Parlora.{AdapterInit, AudioFormat, Limits}
  alias Parlora.Provider.OutputBuffer
  format = %AudioFormat{}
  limits = %Limits{}

  init = %AdapterInit{
    session_id: Parlora.ID.new(),
    adapter_id: "queue-probe",
    generation: 0,
    event_sink: self(),
    audio_format: format,
    limits: limits
  }

  now = System.monotonic_time(:microsecond)

  {:ok, {queue, _sequence}} =
    OutputBuffer.push(
      OutputBuffer.new(limits),
      AudioFormat.silence(format, milliseconds),
      init,
      0,
      now
    )

  Process.sleep(5)

  {:ok, _frames, queue} =
    OutputBuffer.read(queue, 960, limits, System.monotonic_time(:microsecond), init)

  {:ok, _frames, empty} =
    OutputBuffer.read(
      queue,
      limits.provider_audio_queue_bytes,
      limits,
      System.monotonic_time(:microsecond),
      init
    )

  if empty.bytes != 0, do: raise("Queue probe did not drain")
end

runs =
  for index <- 1..48 do
    scenario = Enum.at([:completed, :failed, :rejected, :uncertain], rem(index - 1, 4))
    delay = Enum.at([50, 100, 200, 350], rem(div(index - 1, 4), 4))

    options = [
      backend_delay_ms: delay,
      result: if(scenario == :failed, do: :failed, else: :completed),
      reject_context: scenario == :rejected,
      uncertain: scenario == :uncertain
    ]

    queue_probe.(Enum.at([100, 200, 400], rem(index - 1, 3)))
    id = Task.async(fn -> ParloraObserver.Demo.run(options) end) |> Task.await(15_000)
    IO.puts("#{index}/48 #{scenario}: #{id} (backend delay #{delay} ms)")
    # Leave time between sessions so range graphs show counter increments.
    Process.sleep(750)
    %{session_id: id, scenario: scenario, backend_delay_ms: delay}
  end

:telemetry.detach(handler)

drain = fn drain, acc ->
  receive do
    {:workload_observation, name, values, metadata} ->
      drain.(drain, [
        %{event: Enum.join(name, "."), measurements: values, metadata: metadata} | acc
      ])
  after
    0 -> Enum.reverse(acc)
  end
end

path =
  System.get_env("PARLORA_OBSERVABILITY_EVIDENCE", "/tmp/parlora-observability-workload.json")

File.write!(
  path,
  Jason.encode!(
    %{
      runs: runs,
      native_per_second: System.convert_time_unit(1, :second, :native),
      observations: drain.(drain, [])
    },
    pretty: true
  )
)

IO.puts("Raw timing evidence: #{path}")
IO.puts("Metrics and traces remain available while this process runs.")
Process.sleep(:infinity)
