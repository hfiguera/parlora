Code.require_file("support/stability.ex", __DIR__)
Code.require_file("../examples/support/order_policy.ex", __DIR__)

defmodule Parlora.LiveStability do
  alias Parlora.{ContextUpdate, Event, ID}
  alias Parlora.Channels.LocalAudio
  alias Parlora.Examples.OrderPolicy
  alias Parlora.Providers.OpenAI
  alias Parlora.TestSupport.FakeBackend
  alias Parlora.Validation.Stability

  def run do
    seconds = Stability.integer_env("PARLORA_LIVE_SECONDS", 300, 300)
    {:ok, devices} = LocalAudio.devices("CoreAudio")
    input = Enum.find(devices, &(&1.name == "MacBook Pro Microphone"))
    output = Enum.find(devices, &(&1.name == "MacBook Pro Speakers"))
    start = System.monotonic_time(:millisecond)

    {:ok, session} =
      Parlora.start_session(
        channel:
          {LocalAudio, host: "CoreAudio", input_device: input.id, output_device: output.id},
        provider: {OpenAI, api_key: Application.fetch_env!(:parlora, :example_api_key)},
        backend: {FakeBackend, observer: self()},
        context_policy: {OrderPolicy, []},
        event_sink: self(),
        instructions: """
        Help check fictional orders in English. Keep responses to one short sentence.
        Backchannel policy: Briefly acknowledge requests. Allow long silence without prompting.
        Interruption policy: Yield when the caller interrupts or changes an order.
        Delegation policy:
        Backend tools: Read-only order delivery lookup.
        Delegate when a caller requests a lookup or corrects the number.
        Do not delegate for greetings, status questions, thanks, or casual conversation.
        Ask for missing numbers. Keep conversing during work. Only announce verified current results.
        """
      )

    receive do
      {:parlora_event, %Event{source: :session, type: :ready}} -> :ok
    after
      15_000 -> raise "Live readiness timeout"
    end

    receive do
      {:adapter, :backend, backend} ->
        run_ready(session, backend, start, seconds)
    after
      1_000 -> raise "Backend not observed"
    end
  end

  defp run_ready(session, backend, start, seconds) do
    [{_id, root, _type, _modules}] = Supervisor.which_children(Parlora.Sessions)
    pids = Stability.tree(root)
    :ok = Parlora.control(session, {:input_muted, true})

    :ok =
      Parlora.append_context(session, %ContextUpdate{
        id: ID.new(),
        kind: :instruction,
        provider_generation: 0,
        content: "Briefly greet the caller."
      })

    schedule(seconds)
    Process.send_after(self(), :sample, 1_000)
    Process.send_after(self(), :finish, seconds * 1_000)

    state = %{
      session: session,
      backend: backend,
      pids: pids,
      speech: nil,
      started: start,
      ready_at_us: System.monotonic_time(:microsecond),
      samples: [],
      events: %{},
      discontinuities: %{},
      requests: %{},
      completions: [],
      accepted_ms: [],
      queue_peaks: %{},
      process_peaks: %{},
      last_sample: start,
      max_sample_gap_ms: 0
    }

    try do
      state = loop(state)
      :ok = Parlora.close(session, :finish)
      closed = await_close()

      report = %{
        duration_seconds: seconds,
        events: state.events,
        discontinuities: state.discontinuities,
        backend_requests: map_size(state.requests),
        backend_completion_ms: state.completions,
        completion_to_accept_ms: state.accepted_ms,
        queue_peaks: state.queue_peaks,
        process_peaks: state.process_peaks,
        max_sample_gap_ms: state.max_sample_gap_ms,
        vm_samples: Enum.reverse(state.samples),
        finalized: closed.finalized?,
        usage: closed.usage
      }

      Stability.report(:live_summary, report)

      unless closed.finalized? and map_size(state.requests) >= 2 and state.accepted_ms != [],
        do: raise("Live run did not establish required work and finalization")

      Enum.each(pids, fn pid ->
        if Process.alive?(pid), do: raise("Session process survived close")
      end)
    after
      if Process.alive?(session), do: Parlora.close(session)
    end
  end

  defp schedule(seconds) do
    prompts = [
      {5, "Please check order one two three."},
      {10, "Are you still checking my order?"},
      {15, "Actually, please check order one two four."},
      {40, "Thank you. I will be quiet for a while."},
      {65, "Please check order one two three instead."},
      {95, "I changed my mind. Please check order one two four."},
      {105, "Actually, check order one two three."},
      {145, "Are you still checking my order?"},
      {175, "Please check my order."},
      {190, "Check order one two four."},
      {220, "Actually, check order one two three."},
      {250, "Please check order one two four instead."},
      {275, "Thank you, goodbye."}
    ]

    for {at, text} <- prompts,
        at < seconds - 10,
        do: Process.send_after(self(), {:speak, text}, at * 1_000)
  end

  defp loop(state) do
    receive do
      :finish ->
        state

      {:speak, text} ->
        loop(speak(state, text))

      :speech_finished ->
        :ok = Parlora.control(state.session, {:input_muted, true})
        :ok = Parlora.control(state.session, {:suppress_output, false})
        loop(%{state | speech: nil})

      :sample ->
        next = sample(state)
        Process.send_after(self(), :sample, 1_000)
        loop(next)

      {:submitted, request} ->
        delay =
          case request.task_revision do
            1 -> 18_000
            4 -> 35_000
            _revision -> 3_000
          end

        terminal = if request.task_revision == 3, do: :failed, else: :completed
        Process.send_after(self(), {:complete, request, terminal}, delay)

        loop(%{
          state
          | requests: Map.put(state.requests, request.id, %{start: now(), completed: nil})
        })

      {:complete, request, terminal} ->
        summary =
          if terminal == :completed,
            do: "Order #{request.input.order} is out for delivery today.",
            else: "The lookup failed; no delivery status is available."

        :ok = FakeBackend.complete(state.backend, request, summary, terminal)
        timing = %{state.requests[request.id] | completed: now()}

        loop(%{
          state
          | requests: Map.put(state.requests, request.id, timing),
            completions: [now() - timing.start | state.completions]
        })

      {:parlora_event, %Event{} = event} ->
        loop(event(state, event))

      _other ->
        loop(state)
    end
  end

  defp speak(%{speech: nil} = state, text) do
    :ok = Parlora.control(state.session, {:suppress_output, true})
    :ok = Parlora.control(state.session, {:clear_output, :next})
    :ok = Parlora.control(state.session, {:input_muted, false})
    parent = self()

    pid =
      spawn_link(fn ->
        {_output, 0} =
          System.cmd("/usr/bin/say", ["-v", "Samantha", text], stderr_to_stdout: true)

        Process.sleep(400)
        send(parent, :speech_finished)
      end)

    %{state | speech: pid}
  end

  defp speak(state, _text), do: raise("Synthetic caller overlap at #{now() - state.started} ms")

  defp event(state, %Event{type: type} = event) do
    if type in [:failed, :policy_failed, :policy_rejected], do: raise("Live failure: #{type}")
    state = %{state | events: Map.update(state.events, type, 1, &(&1 + 1))}

    case event do
      %Event{type: :audio_discontinuity, source: source, payload: payload} ->
        phase = if event.observed_at_us < state.ready_at_us, do: :startup, else: :running
        cause = "#{phase}/#{source}/#{Map.get(payload, :cause, :unknown)}"
        %{state | discontinuities: Map.update(state.discontinuities, cause, 1, &(&1 + 1))}

      %Event{type: :result_delivery, request_id: id, payload: %{stage: :accepted}} ->
        case state.requests[id] do
          %{completed: completed} when is_integer(completed) ->
            %{state | accepted_ms: [now() - completed | state.accepted_ms]}

          _unknown ->
            state
        end

      %Event{source: :session, type: :closed} ->
        raise "Live session closed early"

      _other ->
        state
    end
  end

  defp sample(state) do
    queues =
      Enum.reduce(state.pids, %{}, fn pid, acc ->
        # Only inspect adapter queues; never serialize adapter state or its credentials.
        case :sys.get_state(pid) do
          %{inbound: inbound, outbound: outbound} = adapter ->
            if inbound.bytes > inbound.capacity or outbound.bytes > outbound.capacity,
              do: raise("Audio queue capacity exceeded")

            queues =
              if Map.has_key?(adapter, :device),
                do: %{capture_bytes: inbound.bytes, playback_bytes: outbound.bytes},
                else: %{generated_bytes: inbound.bytes, uplink_bytes: outbound.bytes}

            Stability.peaks(acc, queues)

          _other ->
            acc
        end
      end)

    sample = Stability.process_sample(state.pids)
    elapsed = now() - state.started

    samples =
      if rem(div(elapsed, 1_000), 10) == 0,
        do: [%{at_ms: elapsed, vm: Stability.vm_sample()} | state.samples],
        else: state.samples

    if rem(div(elapsed, 1_000), 30) == 0,
      do:
        Stability.report(:live_checkpoint, %{
          elapsed_ms: elapsed,
          requests: map_size(state.requests),
          processes: sample,
          queues: queues
        })

    %{
      state
      | samples: samples,
        process_peaks: Stability.peaks(state.process_peaks, sample),
        queue_peaks: Stability.peaks(state.queue_peaks, queues),
        last_sample: now(),
        max_sample_gap_ms: max(state.max_sample_gap_ms, now() - state.last_sample)
    }
  end

  defp await_close do
    receive do
      {:parlora_event, %Event{source: :session, type: :closed, payload: payload}} ->
        Process.sleep(50)
        payload

      _other ->
        await_close()
    after
      6_000 -> raise "Live close timeout"
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end

Parlora.LiveStability.run()
