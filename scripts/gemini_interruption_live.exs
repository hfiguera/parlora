# MIX_ENV=test diagnostic: real Gemini and production pipelines, an in-memory
# channel and no business work. Measures buffer clearing, not physical playback.
defmodule Parlora.GeminiInterruptionProbe do
  alias Parlora.{AudioFormat, AudioFrame, ContextUpdate, Event, ID}
  alias Parlora.TestSupport.{FakeBackend, MemoryAudio, MemoryChannel, OrderPolicy}

  def run(path) do
    {:ok, session} =
      Parlora.start_session(
        channel: {MemoryChannel, observer: self()},
        provider: {Parlora.Providers.Gemini, api_key: System.fetch_env!("GEMINI_API_KEY")},
        limits: Parlora.Providers.Gemini.audio_limits(),
        backend: {FakeBackend, observer: self()},
        context_policy: {OrderPolicy, []},
        instructions:
          "Tell stories when asked. On an interruption stop your story and follow the new request immediately. This is a conversation test; no backend work is needed.",
        event_sink: self()
      )

    started = now()
    Process.send_after(self(), :tick, 10)
    Process.send_after(self(), :deadline, 40_000)

    state = %{
      session: session,
      channel: nil,
      started: started,
      deadline: started + 40_000,
      ready: false,
      input: <<>>,
      correction: File.read!(path),
      input_started: nil,
      first_audio: nil,
      sequence: 0,
      interrupted: nil,
      cleared: nil,
      epoch: 0,
      fresh_bytes: 0,
      stale_frames: 0,
      captions: [],
      backend_calls: 0,
      idle: false
    }

    loop(state)
  end

  defp loop(state) do
    receive do
      {:adapter, :channel, pid} ->
        loop(%{state | channel: pid})

      {:parlora_event, %Event{source: :session, type: :ready}} ->
        :ok =
          Parlora.append_context(state.session, %ContextUpdate{
            id: ID.new(),
            kind: :speakable,
            provider_generation: 0,
            content:
              "Tell me a detailed story about a sailing adventure, at least twenty sentences. Start now."
          })

        loop(%{state | ready: true})

      {:parlora_event, %Event{type: :transcript_delta, payload: caption}} ->
        row = %{speaker: caption.speaker, text: caption.delta, ms: now() - state.started}
        IO.puts(JSON.encode!(row))
        loop(%{state | captions: state.captions ++ [row], idle: false})

      {:parlora_event, %Event{source: :provider, type: :output_interrupted}} ->
        loop(%{state | interrupted: now()})

      {:parlora_event,
       %Event{source: :channel, type: :control_completed, payload: %{epoch: epoch}}} ->
        loop(%{state | cleared: now(), epoch: epoch})

      {:parlora_event, %Event{type: :delegation_requested}} ->
        loop(%{state | backend_calls: state.backend_calls + 1})

      {:parlora_event, %Event{type: :provider_activity, payload: %{state: :idle}}}
      when state.cleared != nil ->
        loop(%{state | idle: true})

      {:parlora_event, %Event{source: :session, type: type}} when type in [:closed, :failed] ->
        finish(state, type)

      :tick ->
        next = tick(state)

        if next.idle and next.input_started != nil and next.input == <<>> and next.fresh_bytes > 0 do
          finish(next, :idle)
        else
          Process.send_after(self(), :tick, 10)
          loop(next)
        end

      :deadline ->
        finish(state, :timeout)

      _event ->
        loop(state)
    end
  end

  defp tick(%{ready: false} = state), do: state

  defp tick(state) do
    frames = MemoryAudio.drain(state.channel)
    first = if frames != [] and state.first_audio == nil, do: now(), else: state.first_audio
    stale = if state.cleared, do: Enum.count(frames, &(&1.playback_epoch < state.epoch)), else: 0
    fresh = if state.cleared, do: Enum.reduce(frames, 0, &(byte_size(&1.data) + &2)), else: 0

    state = %{
      state
      | first_audio: first,
        stale_frames: state.stale_frames + stale,
        fresh_bytes: state.fresh_bytes + fresh
    }

    state =
      if first && state.input_started == nil && now() - first >= 1_000,
        do: %{state | input: state.correction, input_started: now()},
        else: state

    size = 480

    {chunk, rest} =
      if byte_size(state.input) >= size do
        <<chunk::binary-size(^size), rest::binary>> = state.input
        {chunk, rest}
      else
        {state.input <> :binary.copy(<<0>>, size - byte_size(state.input)), <<>>}
      end

    :ok =
      MemoryAudio.audio(
        state.channel,
        AudioFrame.new(chunk, %AudioFormat{}, "caller", state.sequence)
      )

    %{state | input: rest, sequence: state.sequence + 1}
  end

  defp finish(state, reason) do
    :ok = Parlora.close(state.session)

    answer =
      state.captions
      |> Enum.filter(
        &((&1.speaker == :assistant and state.input_started) &&
            &1.ms >= state.input_started - state.started)
      )
      |> Enum.map_join(& &1.text)

    passed =
      reason == :idle and state.interrupted != nil and state.cleared != nil and
        state.fresh_bytes > 0 and state.stale_frames == 0 and state.backend_calls == 0 and
        String.contains?(String.downcase(answer), "hello")

    IO.puts(
      JSON.encode!(%{
        passed: passed,
        reason: reason,
        epoch: state.epoch,
        interrupted: state.interrupted != nil,
        fresh_audio_bytes: state.fresh_bytes,
        stale_frames_after_clear: state.stale_frames,
        backend_calls: state.backend_calls,
        input_to_clear_ms:
          if(state.cleared && state.input_started, do: state.cleared - state.input_started),
        elapsed_ms: now() - state.started,
        assistant_after_input: answer
      })
    )

    unless passed, do: System.halt(1)
  end

  defp now, do: System.monotonic_time(:millisecond)
end

[path] = System.argv()
Parlora.GeminiInterruptionProbe.run(path)
