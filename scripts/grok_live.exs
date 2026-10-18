# Bounded adapter smoke test. Input is synthetic PCM16LE/24 kHz or PCMU/8 kHz, not a
# human-conversation qualification. Run through with_keychain.py, never with
# a credential in command arguments. No raw audio or secrets are logged.
defmodule Parlora.GrokLiveProbe do
  alias Parlora.{AdapterInit, AudioFormat, AudioFrame, ContextUpdate, Event, ID, Limits}
  alias Parlora.Providers.Grok

  def run(path, format, mode) do
    {:ok, limits} = Limits.new(Grok.audio_limits(format), format)

    init = %AdapterInit{
      session_id: ID.new(),
      adapter_id: ID.new(),
      generation: 0,
      event_sink: self(),
      audio_format: format,
      limits: limits
    }

    {:ok, provider} =
      Grok.start_link(init,
        api_key: System.fetch_env!("XAI_API_KEY"),
        reasoning_effort: reasoning(),
        instructions:
          "You check order delivery status. For every order lookup call delegate_to_backend with the caller's request. Ask for missing order numbers. Never invent results or claim a system error unless the application reports an error. Wait for the actual backend result, then answer briefly."
      )

    started = System.monotonic_time(:millisecond)
    timeout = System.get_env("GROK_PILOT_TIMEOUT_SECONDS", "55") |> String.to_integer()
    true = timeout in 1..120
    Process.send_after(self(), :deadline, timeout * 1_000)

    loop(
      provider,
      init,
      path,
      started,
      %{
        model: "grok-voice-3.0",
        audio_bytes: 0,
        timeout_seconds: timeout,
        captions: [],
        calls: 0,
        submitted: 0,
        failures: [],
        mode: mode,
        codec: format.codec,
        reasoning_effort: reasoning()
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
          Grok.append_context(provider, %ContextUpdate{
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
        :ok = Grok.resume_output(provider, token)
        loop(provider, init, path, started, report, worker)

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

    case Grok.write_audio(provider, frame) do
      :ok -> :ok
      _error -> exit(:normal)
    end

    case Grok.read_audio(provider, init.limits.max_frame_bytes) do
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

    Grok.close(provider, ID.new(), :pilot_complete)
    GenServer.stop(provider)

    conversation =
      report.mode == :conversation and Enum.any?(report.captions, &(&1.speaker == :user)) and
        Enum.any?(report.captions, &(&1.speaker == :assistant))

    passed =
      reason == :idle and report.audio_bytes > 0 and
        (conversation or
           (report.calls > 0 and report.submitted > 0 and
              Enum.any?(
                report.captions,
                &(String.contains?(&1.text, "Friday") and &1.speaker == :assistant)
              )))

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

  defp reasoning do
    case System.get_env("GROK_REASONING_EFFORT", "high") do
      "high" -> :high
      "none" -> :none
      _invalid -> raise "GROK_REASONING_EFFORT must be high or none"
    end
  end

  defp elapsed(started), do: System.monotonic_time(:millisecond) - started
end

[path | flags] = System.argv()
format = if "--pcmu" in flags, do: Parlora.AudioFormat.pcmu(), else: %Parlora.AudioFormat{}

mode =
  cond do
    "--conversation" in flags -> :conversation
    true -> :tool
  end

Parlora.GrokLiveProbe.run(path, format, mode)
