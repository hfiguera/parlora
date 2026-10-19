Code.require_file("../scripts/support/stability.ex", __DIR__)

defmodule Parlora.StabilityTest do
  use ExUnit.Case, async: false
  alias Parlora.{AudioFrame, Event}
  alias Parlora.TestSupport.{FakeBackend, MemoryAudio, MemoryChannel, MemoryProvider, OrderPolicy}
  alias Parlora.Validation.Stability
  @moduletag :stability
  @moduletag timeout: 600_000

  test "seeded correction bursts and repeated sessions remain bounded and clean up" do
    :rand.seed(:exsss, {42, 17, 91})
    cycles = Stability.integer_env("PARLORA_STABILITY_CYCLES", 100, 1_000)
    Stability.report(:instrumentation_warmup, Stability.vm_sample())
    warmup_cycles = warmup(0, 0, 20)
    :erlang.garbage_collect()
    baseline = Stability.vm_sample()

    measurements =
      Enum.map(1..cycles, fn index ->
        mode = Enum.at([:normal, :failure, :disconnect, :cancel], rem(index, 4))
        result = cycle(mode)

        if rem(index, 25) == 0,
          do: Stability.report(:simulated_checkpoint, %{cycle: index, vm: Stability.vm_sample()})

        result
      end)

    :erlang.garbage_collect()
    final = Stability.vm_sample()
    assert final.processes <= baseline.processes + 5
    assert final.beam_bytes <= baseline.beam_bytes + 16_000_000
    assert DynamicSupervisor.count_children(Parlora.Sessions).active == 0
    peak = Enum.reduce(measurements, %{}, &Stability.peaks/2)

    Stability.report(:simulated_summary, %{
      cycles: cycles,
      warmup_cycles: warmup_cycles,
      seed: [42, 17, 91],
      baseline: baseline,
      final: final,
      peaks: peak,
      beam_growth_limit_bytes: 16_000_000
    })
  end

  defp warmup(_previous_code_bytes, 3, _remaining), do: 0

  defp warmup(_previous_code_bytes, _stable, 0),
    do: raise("Code loading did not settle during bounded warmup")

  defp warmup(previous_code_bytes, stable, remaining) do
    for mode <- [:normal, :failure, :disconnect, :cancel], do: cycle(mode)
    code_bytes = :erlang.memory(:code)
    stable = if code_bytes == previous_code_bytes, do: stable + 1, else: 0
    4 + warmup(code_bytes, stable, remaining - 1)
  end

  test "deadline uncertainty, transcript exhaustion, and provider loss have explicit outcomes" do
    {session, _channel, provider, backend, pids} = boot(job_timeout_ms: 30)
    request = request(provider, 123)
    assert_receive {:parlora_event, %Event{type: :request_uncertain}}
    assert Parlora.status(session).jobs[request.id].status == :uncertain
    FakeBackend.complete(backend, request, "late verified result")
    assert_receive {:context, %{content: "late verified result"}}
    finish(session, pids)

    {session, _channel, provider, _backend, pids} = boot(max_transcripts: 8)
    for _fragment <- 1..9, do: transcript(provider, " hello")

    assert_receive {:parlora_event,
                    %Event{type: :failed, payload: %{error: %{code: :backpressure}}}}

    await_cleanup(pids)
    refute Process.alive?(session)
    flush()
  end

  test "one session retains bounded history across many completed corrections" do
    revisions = Stability.integer_env("PARLORA_STABILITY_REVISIONS", 500, 2_000)
    {session, channel, provider, backend, pids} = boot()
    initial = Stability.process_sample(pids)

    latencies =
      Enum.map(1..revisions, fn revision ->
        {us, request} = :timer.tc(fn -> request(provider, 100 + rem(revision, 800)) end)
        FakeBackend.complete(backend, request, "verified revision #{revision}")
        assert_receive {:context, %{task_revision: ^revision}}

        if rem(revision, 50) == 0 do
          audio(channel, provider)
          status = Parlora.status(session)
          assert map_size(status.jobs) == revision
          assert Enum.count(status.jobs, fn {_id, job} -> job.status == :submitted end) <= 1

          Stability.report(:retained_history_checkpoint, %{
            revision: revision,
            processes: Stability.process_sample(pids),
            request_us: us
          })
        end

        us
      end)

    final = Stability.process_sample(pids)
    finish(session, pids)

    Stability.report(:retained_history_summary, %{
      revisions: revisions,
      initial: initial,
      final: final,
      max_request_us: Enum.max(latencies),
      first_request_us: hd(latencies),
      last_request_us: List.last(latencies)
    })
  end

  defp cycle(mode) do
    {session, channel, provider, backend, pids} = boot()
    {startup_us, requests} = :timer.tc(fn -> Enum.map(123..126, &request(provider, &1)) end)
    assert [_first, _second, _third, _fourth] = requests
    assert requests |> MapSet.new(& &1.id) |> MapSet.size() == 4
    status = Parlora.status(session)
    assert map_size(status.jobs) == 4
    assert Enum.count(status.jobs, fn {_id, job} -> job.status == :submitted end) <= 4

    MemoryAudio.inject(provider, :delegation_requested, %{
      id: "delegation",
      offset_ms: 0,
      target: :client
    })

    queue_peak = audio(channel, provider)
    :ok = Parlora.control(session, {:suppress_output, true})
    :ok = Parlora.control(session, {:clear_output, :next})
    :ok = Parlora.control(session, {:suppress_output, false})
    sample = Stability.process_sample(pids)
    assert queue_peak <= 9_600
    complete(mode, session, provider, backend, requests)
    {cleanup_us, :ok} = :timer.tc(fn -> finish(session, pids) end)

    Map.merge(sample, %{
      four_request_us: startup_us,
      cleanup_us: cleanup_us,
      queue_bytes: queue_peak,
      retained_jobs: map_size(status.jobs)
    })
  end

  defp complete(:disconnect, _session, provider, _backend, requests) do
    MemoryAudio.inject(provider, :disconnected, %{reason: :injected_connection_loss})
    assert_receive {:parlora_event, %Event{type: :disconnected}}
    assert_receive {:parlora_event, %Event{source: :session, type: :closed, payload: payload}}
    assert map_size(payload.jobs) == length(requests)
    assert Enum.all?(payload.jobs, fn {_id, outcome} -> outcome == :uncertain end)
  end

  defp complete(mode, session, _provider, backend, requests) do
    latest = List.last(requests)
    if mode == :cancel, do: assert(:ok = Parlora.cancel(session, latest.id, :stability))

    Enum.each(Enum.shuffle(requests), fn request ->
      terminal =
        cond do
          request.id != latest.id -> :completed
          mode == :failure -> :failed
          mode == :cancel -> :cancelled
          true -> :completed
        end

      summary = if terminal == :completed, do: "verified #{request.task_revision}", else: nil
      FakeBackend.complete(backend, request, summary, terminal)
      # Duplicate terminal delivery must not create a second append.
      FakeBackend.complete(backend, request, summary, terminal)
    end)

    if mode == :normal do
      assert_receive {:context, %{content: "verified 4", task_revision: 4}}
    end

    refute_receive {:context, _obsolete_or_duplicate}, 10
    assert_receive {:parlora_event, %Event{type: :stale_result}}

    eventually(fn ->
      Enum.all?(Parlora.status(session).jobs, fn {_id, job} ->
        job.status in [:completed, :failed, :cancelled]
      end)
    end)
  end

  defp request(provider, number) do
    transcript(provider, " check order #{number}")

    MemoryAudio.inject(provider, :delegation_requested, %{
      id: "delegation",
      offset_ms: 0,
      target: :client
    })

    assert_receive {:submitted, request}
    assert request.input.order == Integer.to_string(number)
    request
  end

  defp transcript(provider, delta),
    do:
      MemoryAudio.inject(provider, :transcript_delta, %{
        speaker: :user,
        delta: delta,
        start_ms: 0,
        end_ms: 100
      })

  defp audio(channel, provider) do
    Enum.reduce(1..5, 0, fn index, peak ->
      frame = AudioFrame.pcm(:binary.copy(<<0, 0>>, 240), "stability", index)
      :ok = MemoryAudio.audio(channel, frame)
      :ok = MemoryAudio.audio(provider, frame)
      peak = max(peak, queue_peak([channel, provider]))
      Process.sleep(10)
      MemoryAudio.drain(channel)
      MemoryAudio.drain(provider)
      peak
    end)
  end

  defp queue_peak(pids) do
    pids
    |> Enum.flat_map(fn pid ->
      state = :sys.get_state(pid)
      [state.inbound.bytes, state.outbound.bytes]
    end)
    |> Enum.max()
  end

  defp boot(limits \\ []) do
    {:ok, session} =
      Parlora.start_session(
        channel: {MemoryChannel, observer: self()},
        provider: {MemoryProvider, observer: self()},
        backend: {FakeBackend, observer: self()},
        context_policy: {OrderPolicy, []},
        event_sink: self(),
        limits: limits
      )

    assert_receive {:adapter, :channel, channel}
    assert_receive {:adapter, :provider, provider}
    assert_receive {:adapter, :backend, backend}
    assert_receive {:parlora_event, %Event{source: :session, type: :ready}}
    [{_id, root, _type, _modules}] = Supervisor.which_children(Parlora.Sessions)
    pids = Stability.tree(root)
    on_exit(fn -> finish(session, pids) end)
    {session, channel, provider, backend, pids}
  end

  defp finish(session, pids) do
    if Process.alive?(session), do: Parlora.close(session, :cancel)
    await_cleanup(pids)
    flush()
  end

  defp await_cleanup(pids), do: eventually(fn -> Enum.all?(pids, &(not Process.alive?(&1))) end)

  defp eventually(function, remaining \\ 200)
  defp eventually(function, 0), do: assert(function.())

  defp eventually(function, remaining) do
    unless function.() do
      Process.sleep(5)
      eventually(function, remaining - 1)
    end
  end

  defp flush do
    receive do
      _message -> flush()
    after
      0 -> :ok
    end
  end
end
