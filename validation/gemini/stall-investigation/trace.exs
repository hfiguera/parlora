# Development-only bounded metadata capture. PCM recording requires a separate,
# explicit one-call option; it is never embedded in metadata or state.
defmodule ParloraGeminiStallTrace do
  use GenServer
  alias Parlora.Providers.Gemini.Connection
  alias Parlora.Providers.Gemini.Audio
  alias Parlora.Providers.Gemini.Protocol
  # Diagnostics must never share the server launcher's failure link.
  def start(path, options \\ []), do: GenServer.start(__MODULE__, {path, options})
  def start_link(path), do: GenServer.start_link(__MODULE__, {path, []})

  def format_status(status),
    do: Map.merge(status, %{state: Map.take(status.state, [:count, :bytes]), message: :redacted})

  def init({path, options}) do
    File.mkdir_p!(Path.dirname(path))
    File.chmod!(Path.dirname(path), 0o700)
    {:ok, file} = File.open(path, [:write, :utf8])
    File.chmod!(path, 0o600)
    recording = recording(options)
    Code.ensure_loaded!(Connection)
    Code.ensure_loaded!(Audio)
    Code.ensure_loaded!(Protocol)

    # Only traced Gemini processes are observed. PCM exists transiently in trace
    # messages, is reduced immediately, and is never retained in state or files.
    :erlang.trace_pattern({Audio, :input, 2}, [{:_, [], [{:return_trace}]}], [:local])

    for function <- [{Protocol, :tool_result, 3}, {Protocol, :text, 1}] do
      :erlang.trace_pattern(function, [{:_, [], [{:message, false}, {:return_trace}]}], [:local])
    end

    :erlang.trace_pattern(
      {Connection, :receive, 2},
      [{:_, [], [{:message, false}, {:return_trace}]}],
      [:local]
    )

    :erlang.trace_pattern(
      {Connection, :send, 2},
      [{:_, [], [{:message, false}, {:return_trace}]}],
      [:local]
    )

    :telemetry.attach({__MODULE__, self()}, [:parlora, :event], &__MODULE__.event/4, self())

    {:ok,
     %{
       file: file,
       count: 0,
       bytes: 0,
       providers: [],
       sessions: [],
       socket_writes: %{},
       audio_windows: %{},
       recording: recording
     }}
  end

  def event(_, _, %{source: :provider, type: :ready}, sink) do
    if Process.alive?(sink) do
      :erlang.trace(self(), true, [:call, :monotonic_timestamp, {:tracer, sink}])
      send(sink, {:watch_provider, self()})
    end
  end

  def event(_, _, %{source: :session, type: :ready}, sink),
    do: send(sink, {:watch_session, self()})

  def event(_, _, _, _), do: :ok

  def handle_info({:watch_provider, pid}, s) do
    Process.monitor(pid)

    {:noreply,
     write(%{s | providers: [pid | s.providers]}, %{
       kind: :provider_ready,
       provider: :erlang.phash2(pid)
     })}
  end

  def handle_info({:watch_session, pid}, s) do
    :ok = Parlora.subscribe(pid)
    Process.monitor(pid)
    send(self(), {:sample, pid})
    {:noreply, %{s | sessions: [pid | s.sessions]}}
  end

  def handle_info({:trace_ts, pid, :call, {Audio, :input, [%{codec: :pcm}, pcm]}, time}, s),
    do: {:noreply, measure(s, pid, :before_conversion_24k, pcm, time)}

  def handle_info({:trace_ts, pid, :return_from, {Audio, :input, 2}, {pcm, _audio}, time}, s),
    do: {:noreply, s |> record_pcm(pid, pcm) |> measure(pid, :after_conversion_16k, pcm, time)}

  def handle_info({:trace_ts, pid, :return_from, {Protocol, :tool_result, 3}, command, time}, s) do
    rows =
      for response <- command.toolResponse.functionResponses do
        %{
          id: response.id,
          name: response.name,
          scheduling: response.scheduling,
          will_continue: Map.get(response, :willContinue),
          response_keys: Map.keys(response.response)
        }
      end

    {:noreply,
     write(s, %{
       kind: :tool_response_built,
       provider: :erlang.phash2(pid),
       built_at_us: System.convert_time_unit(time, :native, :microsecond),
       responses: rows
     })}
  end

  def handle_info({:trace_ts, pid, :return_from, {Protocol, :text, 1}, _command, time}, s),
    do:
      {:noreply,
       write(s, %{
         kind: :client_content_built,
         provider: :erlang.phash2(pid),
         built_at_us: System.convert_time_unit(time, :native, :microsecond)
       })}

  def handle_info({:trace_ts, pid, :return_from, mfa, value, _time}, s),
    do: handle_info({:trace, pid, :return_from, mfa, value}, s)

  def handle_info(
        {:trace, pid, :return_from, {Connection, :receive, 2}, {:ok, _socket, frames}},
        s
      ) do
    next =
      Enum.reduce(frames, s, fn
        {kind, json}, acc when kind in [:text, :binary] ->
          case Jason.decode(json) do
            {:ok, value} ->
              write(
                acc,
                Map.merge(summarize(value), %{kind: :wire, provider: :erlang.phash2(pid)})
              )

            _ ->
              write(acc, %{kind: :invalid_json})
          end

        {:close, code, _reason}, acc ->
          write(acc, %{kind: :socket_close, code: code})

        _, acc ->
          acc
      end)

    {:noreply, next}
  end

  def handle_info({:trace, pid, :return_from, {Connection, :receive, 2}, {:error, reason}}, s),
    do:
      {:noreply, write(s, %{kind: :receive_error, provider: :erlang.phash2(pid), reason: reason})}

  def handle_info({:trace, pid, :return_from, {Connection, :send, 2}, {:ok, _socket}}, s) do
    counts = Map.update(s.socket_writes, :erlang.phash2(pid), 1, &(&1 + 1))
    {:noreply, %{s | socket_writes: counts}}
  end

  def handle_info({:trace, pid, :return_from, {Connection, :send, 2}, {:error, reason}}, s),
    do: {:noreply, write(s, %{kind: :send_error, provider: :erlang.phash2(pid), reason: reason})}

  def handle_info({:sample, pid}, s) do
    s = flush_audio(s)

    next =
      try do
        with %{health: health} = status <- Parlora.status(pid) do
          row = %{
            kind: :health,
            session: status.session_id,
            status: status.status,
            activity: status.provider_activity,
            speech: Map.get(status, :provider_speech, :unknown),
            interpretation: status.interpretation,
            socket_writes: s.socket_writes,
            jobs: map_size(status.jobs),
            delegations: map_size(status.delegations),
            input: health.input_forwarded,
            output: health.output_forwarded,
            observations: health.observations,
            expectation: health.expectation
          }

          if s.count < 10_000 and s.bytes < 8_000_000,
            do: Process.send_after(self(), {:sample, pid}, 500)

          write(s, row)
        else
          {:error, _closed_or_unavailable} -> s
        end
      catch
        :exit, _ -> s
      end

    {:noreply, next}
  end

  def handle_info({:parlora_event, e}, s) do
    if e.type in [
         :delegation_requested,
         :delegation_pending,
         :request_started,
         :request_completed,
         :request_failed,
         :failed,
         :closed,
         :output_interrupted,
         :progress_timeout,
         :context_rejected,
         :context_submitted,
         :provider_speech,
         :provider_activity
       ] do
      {:noreply,
       write(s, %{
         kind: :event,
         event: e.type,
         source: e.source,
         session: e.session_id,
         request: e.request_id,
         command: e.command_id,
         state: Map.get(e.payload, :state),
         cause: Map.get(e.payload, :cause)
       })}
    else
      {:noreply, s}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, s) do
    s = s |> close_recording(pid) |> flush_audio()

    {:noreply,
     write(
       %{s | providers: List.delete(s.providers, pid), sessions: List.delete(s.sessions, pid)},
       %{kind: :process_down, process: :erlang.phash2(pid)}
     )}
  end

  def handle_info(_, s), do: {:noreply, s}

  def summarize(value) do
    content = value["serverContent"] || %{}
    parts = get_in(content, ["modelTurn", "parts"]) || []

    %{
      fields: Map.keys(value),
      content_fields: Map.keys(content),
      lifecycle:
        Map.take(content, [
          "turnComplete",
          "generationComplete",
          "interrupted",
          "interactionStatus"
        ]),
      interaction: value["interactionStatus"],
      input_caption: caption(content["inputTranscription"]),
      output_caption: caption(content["outputTranscription"]),
      part_fields: Enum.map(parts, &Map.keys/1),
      audio_encoded_bytes:
        Enum.reduce(parts, 0, fn p, n ->
          n + byte_size(get_in(p, ["inlineData", "data"]) || "")
        end),
      calls:
        Enum.map(
          get_in(value, ["toolCall", "functionCalls"]) || [],
          &Map.take(&1, ["id", "name"])
        ),
      cancelled_ids: get_in(value, ["toolCallCancellation", "ids"]) || [],
      error_code: get_in(value, ["error", "code"])
    }
  end

  defp caption(nil), do: nil

  defp caption(c),
    do: %{chars: String.length(c["text"] || ""), finished: c["finished"], fields: Map.keys(c)}

  # RMS is an energy measurement, not speech detection. The threshold of 328 is
  # approximately -40 dBFS; noise, echo, and speech can all cross it.
  def pcm_summary(pcm) when is_binary(pcm) do
    {samples, squares, peak} =
      for <<sample::little-signed-16 <- pcm>>, reduce: {0, 0, 0} do
        {n, sum, peak} -> {n + 1, sum + sample * sample, max(peak, abs(sample))}
      end

    rms = if samples == 0, do: 0.0, else: :math.sqrt(squares / samples)
    %{samples: samples, peak: peak, rms: rms, above_threshold?: rms >= 328}
  end

  defp measure(s, pid, stage, pcm, timestamp) do
    summary = pcm_summary(pcm)
    time = System.convert_time_unit(timestamp, :native, :microsecond)
    key = {:erlang.phash2(pid), stage}

    window =
      Map.get(s.audio_windows, key, %{
        frames: 0,
        samples: 0,
        peak: 0,
        max_rms: 0.0,
        above_threshold_frames: 0,
        first_at_us: time,
        last_at_us: time,
        max_gap_us: 0,
        first_signal_at_us: nil,
        last_signal_at_us: nil
      })

    signal = summary.above_threshold?

    window = %{
      window
      | frames: window.frames + 1,
        samples: window.samples + summary.samples,
        peak: max(window.peak, summary.peak),
        max_rms: max(window.max_rms, summary.rms),
        above_threshold_frames: window.above_threshold_frames + if(signal, do: 1, else: 0),
        last_at_us: time,
        max_gap_us: max(window.max_gap_us, time - window.last_at_us),
        first_signal_at_us: window.first_signal_at_us || if(signal, do: time),
        last_signal_at_us: if(signal, do: time, else: window.last_signal_at_us)
    }

    %{s | audio_windows: Map.put(s.audio_windows, key, window)}
  end

  defp flush_audio(s) do
    next =
      Enum.reduce(s.audio_windows, s, fn {{provider, stage}, window}, acc ->
        write(acc, Map.merge(window, %{kind: :input_signal, provider: provider, stage: stage}))
      end)

    %{next | audio_windows: %{}}
  end

  # Explicit opt-in only, one provider connection, PCM16LE mono 16 kHz,
  # maximum three minutes. Exclusive create prevents overwriting earlier evidence.
  defp recording(options) do
    case Keyword.get(options, :record_pcm_once) do
      nil ->
        nil

      path ->
        {:ok, file} = File.open(path, [:write, :exclusive, :binary])
        File.chmod!(path, 0o600)
        %{file: file, provider: nil, bytes: 0, closed: false}
    end
  end

  defp record_pcm(%{recording: nil} = s, _pid, _pcm), do: s
  defp record_pcm(%{recording: %{closed: true}} = s, _pid, _pcm), do: s

  defp record_pcm(%{recording: %{provider: provider} = recording} = s, pid, pcm)
       when is_nil(provider) or provider == pid do
    size = min(byte_size(pcm), 180 * 16_000 * 2 - recording.bytes)
    :ok = IO.binwrite(recording.file, binary_part(pcm, 0, size))
    next = %{s | recording: %{recording | provider: pid, bytes: recording.bytes + size}}
    if next.recording.bytes == 180 * 16_000 * 2, do: close_recording(next, pid), else: next
  end

  defp record_pcm(s, _pid, _pcm), do: s

  defp close_recording(%{recording: %{provider: pid, closed: false} = recording} = s, pid) do
    File.close(recording.file)
    %{s | recording: %{recording | closed: true, file: nil}}
  end

  defp close_recording(s, _pid), do: s

  defp write(s, row) do
    if s.count < 10_000 and s.bytes < 8_000_000 do
      data = Jason.encode!(Map.put(row, :at_ms, System.system_time(:millisecond))) <> "\n"
      IO.binwrite(s.file, data)
      %{s | count: s.count + 1, bytes: s.bytes + byte_size(data)}
    else
      Enum.each(s.providers, fn p ->
        if Process.alive?(p), do: :erlang.trace(p, false, [:call])
      end)

      s
    end
  end

  def terminate(_, s) do
    :telemetry.detach({__MODULE__, self()})
    Enum.each(s.providers, fn p -> if Process.alive?(p), do: :erlang.trace(p, false, [:call]) end)
    if s.recording && not s.recording.closed, do: File.close(s.recording.file)
    File.close(s.file)
  end
end
