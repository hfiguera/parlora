# Synthetic caller only; no microphone, physical playback, business actions or raw
# credential/event dumps. Run through scripts/with_keychain.py. Reports contain
# synthetic transcripts and aggregate metadata, not audio or session identifiers.
defmodule Parlora.Live11Probe do
  alias Parlora.{
    AdapterInit,
    AudioFormat,
    AudioFrame,
    ContextSnapshot,
    ContextUpdate,
    Event,
    ID,
    Limits
  }

  alias Parlora.Provider.OutputBuffer
  alias Parlora.Providers.OpenAI

  def run(model, format, directory) do
    {:ok, limits} = Limits.new(OpenAI.audio_limits(format), format)

    init = %AdapterInit{
      session_id: ID.new(),
      adapter_id: ID.new(),
      generation: 0,
      event_sink: self(),
      audio_format: format,
      limits: limits
    }

    delegate =
      if model == "gpt-live-1", do: "Generate <|SpawnThinking|>", else: "Delegate to the backend"

    dont =
      if model == "gpt-live-1", do: "Do not generate <|SpawnThinking|>", else: "Do not delegate"

    instructions = """
    You check fictional order delivery. Reply in the caller's language in one short sentence.
    Backchannel policy: Use brief natural acknowledgments.
    Interruption policy: Stop speaking and listen when the caller corrects the order number.
    Delegation policy:
    Backend tools: Read-only order delivery lookup.
    #{delegate} when the caller requests an order lookup or corrects its number.
    #{dont} for greetings, missing information, or repeating/translating a current result.
    #{delegate} before giving an answer that depends on backend work. Never invent results.
    """

    {:ok, provider} =
      OpenAI.start_link(init,
        api_key: System.fetch_env!("OPENAI_API_KEY"),
        model: model,
        instructions: instructions
      )

    try do
      receive do
        {:parlora_event, %Event{type: :ready}} -> :ok
        {:parlora_event, %Event{type: :failed}} -> raise "Live startup failed for #{model}"
      after
        20_000 -> raise "Live startup timeout for #{model}"
      end

      extension = if format.codec == :pcmu, do: "pcmu", else: "pcm"

      clips =
        for name <- ["lookup", "correction", "spanish"],
            into: %{},
            do: {name, File.read!(Path.join(directory, name <> "." <> extension))}

      started = now()

      report = %{
        model: model,
        codec: format.codec,
        events: %{},
        transcripts: [],
        audio_bytes: 0,
        backpressure_ticks: 0,
        first_audio_ms: nil,
        result_commands: [],
        result_acks: [],
        delegations: [],
        failures: [],
        recovery: false,
        recovery_model: nil,
        finalized: false,
        close_reason: nil,
        usage: nil
      }

      state = %{
        provider: provider,
        init: init,
        started: started,
        sequence: 0,
        input: <<>>,
        clips: clips,
        fired: MapSet.new(),
        report: report,
        next_tick: started
      }

      state = loop(state)
      report = state.report

      checks = %{
        audio: report.audio_bytes > 0,
        lookup_delegated: Enum.any?(report.delegations, &(&1.phase == "lookup")),
        correction_delegated: Enum.any?(report.delegations, &(&1.phase == "correction")),
        result_acknowledged:
          report.result_commands != [] and
            Enum.all?(report.result_commands, &(&1 in report.result_acks)),
        caller_transcribed: Enum.any?(report.transcripts, &(&1.speaker == :user)),
        assistant_transcribed: Enum.any?(report.transcripts, &(&1.speaker == :assistant)),
        recovered_same_model: report.recovery and report.recovery_model == model,
        graceful_close:
          report.close_reason == "close_requested" and report.usage[:final?] == true,
        recovery_usage_honest: not report.finalized and report.usage[:complete?] == false,
        no_failures: report.failures == []
      }

      Map.merge(report, %{checks: checks, passed: Enum.all?(checks, &elem(&1, 1))})
    after
      if Process.alive?(provider) do
        OpenAI.close(provider, ID.new(), :probe_cleanup)
        GenServer.stop(provider)
      end
    end
  end

  defp loop(state) do
    elapsed = now() - state.started

    state =
      Enum.reduce([{1_000, "lookup"}, {10_000, "correction"}, {21_000, "spanish"}], state, fn {at,
                                                                                               name},
                                                                                              s ->
        if elapsed >= at and not MapSet.member?(s.fired, name),
          do: %{s | input: s.clips[name], fired: MapSet.put(s.fired, name)},
          else: s
      end)

    state =
      if elapsed >= 31_000 and not MapSet.member?(state.fired, "recovery") do
        # Force an expired output frame through the actual adapter recovery path.
        :sys.replace_state(state.provider, fn provider ->
          old =
            System.monotonic_time(:microsecond) -
              (provider.init.limits.provider_audio_max_age_ms + 1) * 1_000

          {:ok, {queue, sequence}} =
            OutputBuffer.push(
              OutputBuffer.new(provider.init.limits),
              AudioFormat.silence(provider.init.audio_format, 20),
              provider.init,
              provider.sequence,
              old
            )

          %{provider | inbound: queue, sequence: sequence}
        end)

        %{state | fired: MapSet.put(state.fired, "recovery")}
      else
        state
      end

    state = tick(state)
    state = events(state)

    if elapsed >= 42_000 do
      :ok = OpenAI.close(state.provider, ID.new(), :probe_complete)
      closing(state, now() + 7_000)
    else
      # Do not flood input to catch up after scheduler or network stalls.
      next_tick = max(state.next_tick + 10, now() + 10)
      Process.sleep(max(0, next_tick - now()))
      loop(%{state | next_tick: next_tick})
    end
  end

  defp tick(state) do
    size = AudioFormat.bytes_for_ms(state.init.audio_format, 10)
    silence = AudioFormat.silence(state.init.audio_format, 10)

    {chunk, rest} =
      if byte_size(state.input) >= size do
        <<chunk::binary-size(^size), rest::binary>> = state.input
        {chunk, rest}
      else
        {state.input <> binary_part(silence, 0, size - byte_size(state.input)), <<>>}
      end

    state =
      case OpenAI.write_audio(
             state.provider,
             AudioFrame.new(chunk, state.init.audio_format, "synthetic", state.sequence)
           ) do
        :ok ->
          %{state | input: rest, sequence: state.sequence + 1}

        {:error, %{code: :backpressure}} ->
          update_in(state.report.backpressure_ticks, &(&1 + 1))

        {:error, %{code: code}} ->
          raise "Audio input failed: #{code}"
      end

    {:ok, frames} = OpenAI.read_audio(state.provider, state.init.limits.max_frame_bytes * 10)
    bytes = Enum.sum(Enum.map(frames, &byte_size(&1.data)))

    report = %{
      state.report
      | audio_bytes: state.report.audio_bytes + bytes,
        first_audio_ms: state.report.first_audio_ms || if(bytes > 0, do: now() - state.started)
    }

    %{state | report: report}
  end

  defp events(state) do
    receive do
      {:parlora_event, %Event{} = event} -> events(event(state, event))
    after
      0 -> state
    end
  end

  defp event(state, event) do
    state = update_in(state.report.events, &Map.update(&1, event.type, 1, fn n -> n + 1 end))
    elapsed = now() - state.started

    case event do
      %Event{type: :transcript_delta, payload: payload} ->
        update_in(
          state.report.transcripts,
          &(&1 ++ [%{speaker: payload.speaker, text: payload.delta, ms: elapsed}])
        )

      %Event{type: :delegation_requested, payload: payload} ->
        phase =
          cond do
            elapsed < 10_000 -> "lookup"
            elapsed < 21_000 -> "correction"
            true -> "repeat"
          end

        order = if phase == "lookup", do: "123", else: "124"
        id = ID.new()

        :ok =
          OpenAI.append_context(state.provider, %ContextUpdate{
            id: id,
            kind: :speakable,
            delegation_id: payload.id,
            provider_generation: 0,
            content:
              "Verified read-only lookup: order #{order} arrives Friday. No changes were made."
          })

        state
        |> update_in([:report, :result_commands], &(&1 ++ [id]))
        |> update_in([:report, :delegations], &(&1 ++ [%{phase: phase, ms: elapsed}]))

      %Event{type: :context_acknowledged, command_id: id} ->
        update_in(state.report.result_acks, &(&1 ++ [id]))

      %Event{type: :output_recovery_requested, payload: %{token: token}} ->
        transcripts =
          Enum.map(state.report.transcripts, &%{speaker: &1.speaker, delta: &1.text})
          |> Enum.reverse()

        :ok =
          OpenAI.recover_output(state.provider, token, %ContextSnapshot{transcripts: transcripts})

        state

      %Event{type: :output_recovered} ->
        model = :sys.get_state(state.provider).startup.session.model
        %{state | report: %{state.report | recovery: true, recovery_model: model}}

      %Event{type: type} when type in [:failed, :context_rejected, :control_failed] ->
        update_in(state.report.failures, &(&1 ++ [%{type: type, ms: elapsed}]))

      %Event{type: :closed, payload: payload} ->
        %{
          state
          | report: %{
              state.report
              | finalized: payload.finalized?,
                close_reason: payload[:reason],
                usage: payload[:usage]
            }
        }

      _ ->
        state
    end
  end

  defp closing(state, deadline) do
    receive do
      {:parlora_event, %Event{type: :closed} = event} -> event(state, event)
      {:parlora_event, event} -> closing(event(state, event), deadline)
    after
      max(0, deadline - now()) -> raise "Live finalization timeout"
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end

[directory, output] = System.argv()

cases =
  for model <- ["gpt-live-1", "gpt-live-1.1"],
      format <- [%Parlora.AudioFormat{}, Parlora.AudioFormat.pcmu()],
      do: {model, format}

reports =
  cases
  |> Task.async_stream(
    fn {model, format} ->
      Parlora.Live11Probe.run(model, format, directory)
    end,
    max_concurrency: 4,
    timeout: 75_000
  )
  |> Enum.map(fn {:ok, report} -> report end)

File.write!(output, JSON.encode!(%{reports: reports}))

Enum.each(reports, fn report ->
  IO.puts(
    JSON.encode!(
      Map.take(report, [
        :model,
        :codec,
        :passed,
        :checks,
        :first_audio_ms,
        :audio_bytes,
        :events,
        :usage
      ])
    )
  )
end)

unless Enum.all?(reports, & &1.passed), do: System.halt(1)
