alias Parlora.{AudioFormat, Event}
alias Parlora.Provider.OutputBuffer
alias Parlora.Providers.OpenAI
alias Parlora.TestSupport.{MemoryAudio, MemoryChannel, FakeBackend, OrderPolicy}

defmodule LiveOutputRecoveryProbe do
  def wait(type, deadline, events \\ []) do
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining <= 0, do: raise("Live recovery probe deadline expired")

    receive do
      {:parlora_event, %{type: ^type} = event} -> {event, [event | events]}
      {:parlora_event, %{type: :failed}} -> raise("Live recovery probe provider failed")
      {:parlora_event, event} -> wait(type, deadline, [event | events])
      _other -> wait(type, deadline, events)
    after
      remaining -> raise("Live recovery probe deadline expired")
    end
  end

  def drain(channel) do
    receive do
      :stop -> :ok
    after
      10 ->
        MemoryAudio.drain(channel)
        drain(channel)
    end
  end
end

{:ok, session} =
  Parlora.start_session(
    channel: {MemoryChannel, observer: self()},
    provider: {OpenAI, api_key: System.fetch_env!("OPENAI_API_KEY")},
    backend: {FakeBackend, observer: self()},
    context_policy: {OrderPolicy, []},
    event_sink: self(),
    instructions: "Speak English briefly. Do not call tools without a new caller request."
  )

{_ready, _events} =
  LiveOutputRecoveryProbe.wait(:ready, System.monotonic_time(:millisecond) + 20_000)

# The first ready can be an adapter; wait for the coordinated media path.
if Parlora.status(session).status != :ready do
  LiveOutputRecoveryProbe.wait(:ready, System.monotonic_time(:millisecond) + 20_000)
end

# Barrier on status avoids relying on ordering among adapter readiness events.
Enum.reduce_while(1..200, nil, fn _, _ ->
  if Parlora.status(session).status == :ready,
    do: {:halt, nil},
    else:
      (
        Process.sleep(10)
        {:cont, nil}
      )
end)

before = :sys.get_state(session)
{_, channel} = before.adapters.channel
{_, provider} = before.adapters.provider
drainer = spawn(fn -> LiveOutputRecoveryProbe.drain(channel) end)
started = System.monotonic_time(:millisecond)

try do
  :sys.replace_state(provider, fn state ->
    old =
      System.monotonic_time(:microsecond) -
        (state.init.limits.provider_audio_max_age_ms + 1) * 1_000

    pcm = AudioFormat.silence(state.init.audio_format, 20)

    {:ok, {queue, sequence}} =
      OutputBuffer.push(OutputBuffer.new(state.init.limits), pcm, state.init, state.sequence, old)

    %{state | inbound: queue, sequence: sequence}
  end)

  {_recovered, events} = LiveOutputRecoveryProbe.wait(:output_recovered, started + 7_000)
  elapsed = System.monotonic_time(:millisecond) - started
  after_state = :sys.get_state(session)

  if after_state.adapters != before.adapters,
    do: raise("Recovery replaced a caller or backend process")

  if after_state.status != :ready, do: raise("Recovery did not retain a ready session")

  if after_state.output_recovery.stage != :awaiting_user,
    do: raise("Recovery did not hold results for fresh caller speech")

  Process.sleep(1_000)
  voice = :sys.get_state(provider)

  report = %{
    provider: "gpt-live-1",
    forced_condition: "expired received audio",
    recovery_ms: elapsed,
    caller_and_backend_preserved: true,
    session_status: after_state.status,
    result_hold: after_state.output_recovery.stage,
    provider_status: voice.status,
    transport_epoch: voice.transport_epoch,
    receive_capacity_bytes: voice.inbound.capacity,
    replacement_audio_frames: voice.sequence - 2,
    discontinuities:
      for(
        %Event{type: :audio_discontinuity, payload: payload} <- events,
        do: Map.take(payload, [:cause, :direction, :dropped_bytes, :dropped_duration_us])
      )
  }

  File.write!(
    "validation/output-recovery-20261004/live.json",
    Jason.encode!(report, pretty: true)
  )

  IO.puts(Jason.encode!(report))
after
  Parlora.close(session)
  send(drainer, :stop)
end

LiveOutputRecoveryProbe.wait(:closed, System.monotonic_time(:millisecond) + 7_000)
