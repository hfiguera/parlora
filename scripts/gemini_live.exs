# Bounded adapter smoke test. Input is synthetic PCM16LE/24 kHz or PCMU/8 kHz, not a
# human-conversation qualification. Run through with_keychain.py, never with
# a credential in command arguments. No raw audio or secrets are logged.
defmodule Parlora.GeminiLiveProbe do
  alias Parlora.{AdapterInit, AudioFormat, AudioFrame, ContextUpdate, Event, ID, Limits}
  alias Parlora.Providers.Gemini

  def run(path, format, mode) do
    {:ok, limits} = Limits.new(Gemini.audio_limits(format), format)

    init = %AdapterInit{
      session_id: ID.new(),
      adapter_id: ID.new(),
      generation: 0,
      event_sink: self(),
      audio_format: format,
      limits: limits
    }

    {:ok, provider} =
      Gemini.start_link(init,
        api_key: System.fetch_env!("GEMINI_API_KEY"),
        instructions:
          "You check order delivery status. For every order lookup call delegate_to_backend with the caller's request. Ask for missing order numbers. Never invent results or claim a system error unless the application reports an error. Wait for the actual backend result, then answer briefly."
      )

    started = System.monotonic_time(:millisecond)
    timeout = System.get_env("GEMINI_PILOT_TIMEOUT_SECONDS", "55") |> String.to_integer()
    true = timeout in 1..120
    Process.send_after(self(), :deadline, timeout * 1_000)

    loop(
      provider,
      init,
      path,
      started,
      %{
        model: "gemini-3.8-live",
        audio_bytes: 0,
        timeout_seconds: timeout,
        captions: [],
        calls: 0,
        submitted: 0,
        failures: [],
        mode: mode,
        codec: format.codec,
        resumed: false
      },
      nil
    )
  end

  defp loop(provider, init, path, started, report, worker) do
    receive do
      {:parlora_event, %Event{type: :ready}} ->
        owner = self()
        worker = spawn_link(fn -> audio_loop(provider, init, File.read!(path), 0, owner) end)
        loop(provider, init, path, started, report, worker)

      {:audio_bytes, bytes} ->
        loop(
          provider,
          init,
          path,
          started,
          %{report | audio_bytes: report.audio_bytes + bytes},
          worker
        )

      {:parlora_event, %Event{type: :transcript_delta, payload: payload}} ->
        row = %{speaker: payload.speaker, text: payload.delta, ms: elapsed(started)}
        IO.puts(Jason.encode!(row))
        loop(provider, init, path, started, %{report | captions: [row | report.captions]}, worker)

      {:parlora_event, %Event{type: :delegation_requested, payload: payload}} ->
        Process.send_after(self(), {:result, payload.id}, 3_000)
        IO.puts(Jason.encode!(%{event: :delegation, ms: elapsed(started)}))
        loop(provider, init, path, started, %{report | calls: report.calls + 1}, worker)

      {:result, id} ->
        result =
          Gemini.append_context(provider, %ContextUpdate{
            id: ID.new(),
            kind: :speakable,
            delegation_id: id,
            provider_generation: 0,
            content: "Order 124 is arriving Friday."
          })

        IO.puts(Jason.encode!(%{event: :result_sent, ok: result == :ok, ms: elapsed(started)}))
        loop(provider, init, path, started, report, worker)

      {:parlora_event, %Event{type: :context_submitted}} ->
        loop(provider, init, path, started, %{report | submitted: report.submitted + 1}, worker)

      {:parlora_event, %Event{type: :output_interrupted, payload: %{token: token}}} ->
        :ok = Gemini.resume_output(provider, token)
        loop(provider, init, path, started, report, worker)

      {:parlora_event, %Event{type: :provider_activity, payload: %{state: :idle}}}
      when report.mode == :resumption and not report.resumed ->
        Process.send_after(self(), :attempt_resume, 100)
        loop(provider, init, path, started, report, worker)

      :attempt_resume ->
        owner = self()
        # Test-only injected GoAway after an actual idle resumable API session.
        # The production adapter owns the close, delay, setup and handle reuse.
        :sys.replace_state(provider, fn state ->
          if state.activity == :idle and state.resumable and
               not Parlora.Providers.Gemini.Calls.pending?(state.calls) do
            {:noreply, next} =
              Gemini.handle_info({:go_away_deadline, state.connection_epoch}, %{
                state
                | go_away: true
              })

            next
          else
            Process.send_after(owner, :attempt_resume, 100)
            state
          end
        end)

        loop(provider, init, path, started, report, worker)

      {:parlora_event, %Event{type: :provider_connection, payload: %{state: :resumed}}} ->
        :ok =
          Gemini.append_context(provider, %ContextUpdate{
            id: ID.new(),
            kind: :speakable,
            provider_generation: 0,
            content:
              "What was the reference number I gave you before the connection resumed? Answer with that reference number."
          })

        loop(provider, init, path, started, %{report | resumed: true, captions: []}, worker)

      {:parlora_event, %Event{type: :provider_activity, payload: %{state: :idle}}}
      when report.submitted > 0 or report.mode == :conversation ->
        finish(provider, worker, report, started, :idle)

      {:parlora_event, %Event{type: :failed, payload: %{error: error}}} ->
        finish(provider, worker, %{report | failures: [error.details]}, started, :failed)

      {:parlora_event, %Event{type: :closed}} ->
        finish(provider, worker, report, started, :closed)

      :deadline ->
        finish(provider, worker, report, started, :timeout)

      _event ->
        loop(provider, init, path, started, report, worker)
    end
  end

  defp audio_loop(provider, init, input, sequence, owner) do
    size = AudioFormat.bytes_for_ms(init.audio_format, 10)

    {chunk, rest} =
      if byte_size(input) >= size do
        <<chunk::binary-size(^size), rest::binary>> = input
        {chunk, rest}
      else
        silence = AudioFormat.silence(init.audio_format, 10)
        {input <> binary_part(silence, 0, size - byte_size(input)), <<>>}
      end

    frame = AudioFrame.new(chunk, init.audio_format, "pilot", sequence)

    case Gemini.write_audio(provider, frame) do
      :ok -> :ok
      _error -> exit(:normal)
    end

    case Gemini.read_audio(provider, init.limits.max_frame_bytes) do
      {:ok, frames} ->
        send(owner, {:audio_bytes, Enum.reduce(frames, 0, &(byte_size(&1.data) + &2))})

      _error ->
        :ok
    end

    Process.sleep(10)
    audio_loop(provider, init, rest, sequence + 1, owner)
  end

  defp finish(provider, worker, report, started, reason) do
    if worker do
      Process.unlink(worker)
      Process.exit(worker, :kill)
    end

    Gemini.close(provider, ID.new(), :pilot_complete)
    GenServer.stop(provider)

    conversation =
      report.mode == :conversation and Enum.any?(report.captions, &(&1.speaker == :user)) and
        Enum.any?(report.captions, &(&1.speaker == :assistant))

    passed =
      reason == :idle and report.audio_bytes > 0 and
        (conversation or
           (report.resumed and Enum.any?(report.captions, &String.contains?(&1.text, "124"))) or
           (report.calls > 0 and report.submitted > 0))

    IO.puts(
      Jason.encode!(%{
        result: reason,
        passed: passed,
        elapsed_ms: elapsed(started),
        report: report
      })
    )

    unless passed, do: System.halt(1)
  end

  defp elapsed(started), do: System.monotonic_time(:millisecond) - started
end

[path | flags] = System.argv()
format = if "--pcmu" in flags, do: Parlora.AudioFormat.pcmu(), else: %Parlora.AudioFormat{}

mode =
  cond do
    "--resumption" in flags -> :resumption
    "--conversation" in flags -> :conversation
    true -> :tool
  end

Parlora.GeminiLiveProbe.run(path, format, mode)
