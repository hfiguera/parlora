# Bounded provider format probe. Requires MIX_ENV=test and an explicit environment key.
Logger.configure(level: :warning)

defmodule Parlora.LiveMuLawProbe do
  alias Parlora.{AudioFormat, ContextUpdate, Event, ID}
  alias Parlora.TestSupport.{FakeBackend, MemoryAudio, MemoryChannel, OrderPolicy}

  def run do
    format = AudioFormat.pcmu()
    caps = %Parlora.Channel.Capabilities{input_formats: [format], output_formats: [format],
      full_duplex?: true, output_suppression?: true, clear_scope: :parlora_buffers, playback_evidence: [:queue]}
    {:ok, session} = Parlora.start_session(audio_format: format,
      channel: {MemoryChannel, observer: self(), capabilities: caps},
      provider: {Parlora.Providers.OpenAI, api_key: System.fetch_env!("OPENAI_API_KEY")},
      backend: {FakeBackend, observer: self()}, context_policy: {OrderPolicy, []}, event_sink: self(),
      instructions: "Speak briefly in English. This is an audio format test.")

    receive do
      {:adapter, :channel, channel} ->
        report = loop(session, channel, %{ready: false, bytes: 0, nonsilent_bytes: 0,
          errors: [], formats_valid: true}, System.monotonic_time(:millisecond) + 12_000)
        report = if Map.has_key?(report, :finalized) do
          report
        else
          Parlora.close(session)
          finalize(report, System.monotonic_time(:millisecond) + 7_000)
        end
        IO.puts(Jason.encode!(report))
    after
      2_000 -> raise "Probe channel did not attach"
    end
  end

  defp loop(session, channel, report, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      report
    else
      report = receive do
        {:parlora_event, %Event{source: :session, type: :ready}} ->
          :ok = Parlora.append_context(session, %ContextUpdate{id: ID.new(), kind: :instruction,
            content: "Speak first now in English. Say hello briefly.", provider_generation: 0})
          %{report | ready: true}
        {:parlora_event, %Event{source: :session, type: :closed, payload: payload}} ->
          Map.merge(report, %{finalized: payload.finalized?, usage: payload.usage})
        {:parlora_event, %Event{type: type, source: source, payload: payload}} when type in [:failed, :audio_discontinuity, :control_failed, :context_rejected] ->
          error = %{type: type, source: source, diagnostics: Map.take(payload, [:cause, :queue_bytes, :incoming_bytes, :capacity_bytes, :max_age_ms])}
          error = case payload[:error] do
            %Parlora.Error{} = detail -> Map.put(error, :error, Map.take(detail, [:code, :message, :details]))
            _none -> error
          end
          IO.puts(Jason.encode!(%{observation: error}))
          %{report | errors: [error | report.errors]}
        _event -> report
      after
        5 -> report
      end
      report = case MemoryAudio.drain(channel) do
        frames when is_list(frames) -> Enum.reduce(frames, report, &count/2)
        _not_ready -> report
      end
      if Map.has_key?(report, :finalized), do: report, else: loop(session, channel, report, deadline)
    end
  end

  defp count(frame, report) do
    nonsilent = for <<byte <- frame.data>>, byte not in [127, 255], reduce: 0 do
      count -> count + 1
    end
    %{report | bytes: report.bytes + byte_size(frame.data), nonsilent_bytes: report.nonsilent_bytes + nonsilent,
      formats_valid: report.formats_valid and frame.format == AudioFormat.pcmu() and frame.duration_us == byte_size(frame.data) * 125}
  end

  defp finalize(report, deadline) do
    receive do
      {:parlora_event, %Event{source: :session, type: :closed, payload: payload}} ->
        Map.merge(report, %{finalized: payload.finalized?, usage: payload.usage})
      _event -> finalize(report, deadline)
    after
      max(0, deadline - System.monotonic_time(:millisecond)) -> Map.put(report, :finalized, false)
    end
  end
end

Parlora.LiveMuLawProbe.run()
