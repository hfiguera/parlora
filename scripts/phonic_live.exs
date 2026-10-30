defmodule Parlora.PhonicLiveProbe do
  @moduledoc false
  alias Parlora.{AdapterInit, AudioFormat, AudioFrame, ContextUpdate, Event, ID, Limits}
  alias Parlora.Providers.Phonic

  def run(path, codec, output) do
    format = if codec == "pcmu", do: AudioFormat.pcmu(), else: %AudioFormat{}
    {:ok, limits} = Limits.new(Phonic.audio_limits(format), format)

    init = %AdapterInit{
      session_id: ID.new(),
      adapter_id: ID.new(),
      generation: 0,
      event_sink: self(),
      audio_format: format,
      limits: limits
    }

    {:ok, provider} =
      Phonic.start_link(init,
        api_key: System.fetch_env!("PHONIC_API_KEY"),
        instructions:
          "This is a synthetic protocol test. For order lookups call delegate_to_backend. Announce only verified results. Keep replies brief and speak English."
      )

    Process.send_after(self(), :deadline, 45_000)

    report = %{
      model: "phonic-1",
      codec: codec,
      synthetic_speech: true,
      wire_format: "pcm_24000",
      audio_bytes: 0,
      calls: 0,
      submissions: 0,
      acknowledgments: 0,
      captions: [],
      failures: [],
      ready: false
    }

    loop(provider, init, File.read!(path), nil, report, output)
  end

  defp loop(provider, init, audio, worker, report, output) do
    receive do
      {:parlora_event, %Event{type: :ready}} ->
        owner = self()
        worker = spawn_link(fn -> pump(provider, init, audio, 0, owner) end)
        loop(provider, init, audio, worker, %{report | ready: true}, output)

      {:parlora_event, %Event{type: :delegation_requested, payload: payload}} ->
        Process.send_after(self(), {:result, payload.id}, 3_000)
        loop(provider, init, audio, worker, %{report | calls: report.calls + 1}, output)

      {:result, id} ->
        reply =
          Phonic.append_context(provider, %ContextUpdate{
            id: ID.new(),
            kind: :speakable,
            provider_generation: 0,
            delegation_id: id,
            content: "Order 123 has shipped. Its estimated delivery is Friday."
          })

        report =
          if reply == :ok,
            do: report,
            else: %{report | failures: [:result_rejected | report.failures]}

        loop(provider, init, audio, worker, report, output)

      {:parlora_event, %Event{type: :context_submitted}} ->
        loop(
          provider,
          init,
          audio,
          worker,
          %{report | submissions: report.submissions + 1},
          output
        )

      {:parlora_event, %Event{type: :context_acknowledged}} ->
        loop(
          provider,
          init,
          audio,
          worker,
          %{report | acknowledgments: report.acknowledgments + 1},
          output
        )

      {:parlora_event, %Event{type: :transcript_delta, payload: payload}} ->
        row = Map.take(payload, [:speaker, :delta])
        loop(provider, init, audio, worker, %{report | captions: [row | report.captions]}, output)

      {:parlora_event, %Event{type: :output_interrupted, payload: %{token: token}}} ->
        :ok = Phonic.resume_output(provider, token)
        loop(provider, init, audio, worker, report, output)

      {:parlora_event, %Event{type: :provider_speech, payload: %{state: :idle}}} ->
        if report.submissions > 0 and String.contains?(assistant_text(report), "Friday"),
          do: finish(provider, worker, report, output, :completed),
          else: loop(provider, init, audio, worker, report, output)

      {:parlora_event, %Event{type: :failed, payload: %{error: error}}} ->
        finish(
          provider,
          worker,
          %{report | failures: [error.details | report.failures]},
          output,
          :failed
        )

      {:parlora_event, %Event{type: :closed}} ->
        finish(provider, worker, report, output, :closed)

      {:audio_bytes, bytes} ->
        loop(
          provider,
          init,
          audio,
          worker,
          %{report | audio_bytes: report.audio_bytes + bytes},
          output
        )

      :deadline ->
        finish(provider, worker, report, output, :timeout)

      _event ->
        loop(provider, init, audio, worker, report, output)
    end
  end

  defp pump(provider, init, audio, sequence, owner) do
    size = AudioFormat.bytes_for_ms(init.audio_format, 10)
    count = min(byte_size(audio), size)
    <<chunk::binary-size(^count), rest::binary>> = audio
    silence = AudioFormat.silence(init.audio_format, 10)
    chunk = chunk <> binary_part(silence, 0, size - count)
    frame = AudioFrame.new(chunk, init.audio_format, "synthetic", sequence)

    with :ok <- Phonic.write_audio(provider, frame),
         {:ok, frames} <- Phonic.read_audio(provider, init.limits.max_frame_bytes) do
      send(owner, {:audio_bytes, Enum.reduce(frames, 0, &(byte_size(&1.data) + &2))})
      Process.sleep(10)
      pump(provider, init, rest, sequence + 1, owner)
    end
  end

  defp assistant_text(report) do
    report.captions
    |> Enum.reverse()
    |> Enum.filter(&(&1.speaker == :assistant))
    |> Enum.map_join(& &1.delta)
  end

  defp finish(provider, worker, report, output, reason) do
    if worker do
      Process.unlink(worker)
      Process.exit(worker, :kill)
    end

    :ok = Phonic.close(provider, ID.new(), :probe_complete)
    GenServer.stop(provider)

    passed =
      reason == :completed and report.calls == 1 and report.audio_bytes > 0 and
        report.acknowledgments > 0 and
        report.failures == []

    report =
      Map.merge(report, %{passed: passed, result: reason, captions: Enum.reverse(report.captions)})

    File.mkdir_p!(Path.dirname(output))
    File.write!(output, JSON.encode!(report))

    IO.puts(
      JSON.encode!(
        Map.take(report, [:passed, :codec, :calls, :submissions, :acknowledgments, :result])
      )
    )

    unless passed, do: System.halt(1)
  end
end

[path, codec, output] = System.argv()
true = codec in ["pcm", "pcmu"]
Parlora.PhonicLiveProbe.run(path, codec, output)
