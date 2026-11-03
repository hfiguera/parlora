defmodule BookingDesk.Recorder do
  @moduledoc "Explicit bounded raw PCM capture and allowlisted evidence for fictional demo calls."
  use GenServer
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def observer(pid), do: GenServer.call(pid, :observer)
  def mark(pid, label, data \\ %{}), do: GenServer.cast(pid, {:mark, label, data})
  def finish(pid, summary), do: GenServer.call(pid, {:finish, summary}, 10_000)
  def event(pid, event), do: GenServer.cast(pid, {:event, event})

  def init(opts) do
    directory = Keyword.fetch!(opts, :directory)
    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)

    files =
      Map.new([:input, :output], fn direction ->
        path = Path.join(directory, "#{direction}.pcm")
        {:ok, file} = File.open(path, [:write, :binary, :exclusive])
        File.chmod!(path, 0o600)
        {direction, file}
      end)

    {:ok, event_file} =
      File.open(Path.join(directory, "events.jsonl"), [:write, :binary, :exclusive])

    File.chmod!(Path.join(directory, "events.jsonl"), 0o600)
    credits = :atomics.new(2, [])
    origin = System.monotonic_time(:microsecond)
    id = "booking-recorder-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        id,
        Parlora.Telemetry.events() ++
          [
            [:booking_desk, :judgment, :stop],
            [:booking_desk, :readback, :stop],
            [:booking_desk, :extraction, :stop],
            [:booking_desk, :guard, :stop]
          ],
        &__MODULE__.telemetry/4,
        %{pid: self(), credits: credits}
      )

    {:ok,
     %{
       directory: directory,
       event_file: event_file,
       files: files,
       credits: credits,
       origin: origin,
       id: id,
       events: [],
       count: 0,
       sampled_at: %{},
       sampled_events: 0,
       dropped_events: 0,
       chunks: [],
       sizes: %{input: 0, output: 0},
       complete: false
     }}
  end

  def format_status(status),
    do:
      Map.merge(status, %{
        state: %{complete: status.state.complete, events: status.state.count},
        message: :redacted
      })

  # Runtime telemetry mirrors the events already sent to this recorder. Keep
  # operation spans, but do not spend the event budget on duplicate per-frame rows.
  def telemetry([:parlora, :runtime, :event], _measurements, _metadata, _observer), do: :ok

  def telemetry(name, measurements, metadata, observer) do
    if :atomics.add_get(observer.credits, 1, 1) <= 256 do
      send(
        observer.pid,
        {:observation, name, measurements, metadata, System.monotonic_time(:microsecond)}
      )
    else
      :atomics.sub(observer.credits, 1, 1)
      :atomics.add(observer.credits, 2, 1)
    end
  end

  def handle_call(:observer, _from, s), do: {:reply, %{pid: self(), credits: s.credits}, s}

  def handle_call({:finish, summary}, _from, s) do
    :telemetry.detach(s.id)
    Enum.each(s.files, fn {_, file} -> File.close(file) end)
    File.close(s.event_file)

    report =
      Map.merge(summary, %{
        schema: 1,
        captured_at: DateTime.to_iso8601(DateTime.utc_now()),
        duration_ms: relative(s, System.monotonic_time(:microsecond)),
        events: Enum.reverse(s.events),
        event_log: %{sampled_playback_events: s.sampled_events, dropped_events: s.dropped_events},
        audio: %{
          sample_rate: 24_000,
          max_duration_ms: 240_000,
          encoding: "pcm_s16le",
          chunks: Enum.reverse(s.chunks),
          dropped_packets: :atomics.get(s.credits, 2),
          boundary: "software_playout_before_device_conversion"
        }
      })

    path = Path.join(s.directory, "session.json")
    File.write!(path, JSON.encode!(report))
    File.chmod!(path, 0o600)
    {:reply, report, %{s | complete: true}}
  end

  def handle_cast({:mark, label, data}, s),
    do:
      {:noreply,
       add(s, %{
         kind: "marker",
         name: label,
         data: data,
         at_ms: relative(s, System.monotonic_time(:microsecond))
       })}

  def handle_cast({:event, event}, s) do
    row = %{
      kind: "event",
      source: event.source,
      name: event.type,
      at_ms: relative(s, event.observed_at_us),
      request_id: event.request_id,
      data: selected(event)
    }

    {:noreply, add(s, row)}
  end

  def handle_info({:parlora_audio, _direction, _at, _pcm}, %{complete: true} = s) do
    :atomics.sub(s.credits, 1, 1)
    {:noreply, s}
  end

  def handle_info({:parlora_audio, direction, at, pcm}, s) do
    :atomics.sub(s.credits, 1, 1)

    if s.sizes[direction] + byte_size(pcm) <= 24_000 * 2 * 240 do
      :ok = IO.binwrite(s.files[direction], pcm)

      chunk = %{
        direction: direction,
        at_ms: relative(s, at),
        offset: s.sizes[direction],
        bytes: byte_size(pcm)
      }

      {:noreply,
       %{
         s
         | chunks: [chunk | s.chunks],
           sizes: Map.update!(s.sizes, direction, &(&1 + byte_size(pcm)))
       }}
    else
      :atomics.add(s.credits, 2, 1)
      {:noreply, s}
    end
  end

  def handle_info({:observation, name, measurements, metadata, at}, s) do
    :atomics.sub(s.credits, 1, 1)

    row = %{
      kind: "telemetry",
      name: Enum.join(name, "."),
      at_ms: relative(s, at),
      data:
        Map.take(metadata, [
          :operation_id,
          :session_id,
          :provider_generation,
          :caller_cursor,
          :parent_operation_id,
          :request_id,
          :task_id,
          :task_revision,
          :outcome,
          :reason,
          :field
        ]),
      measurements: Map.take(measurements, [:duration, :duration_us, :count, :attempt])
    }

    {:noreply, add(s, row)}
  end

  defp add(%{complete: true} = s, _row), do: s

  # LocalAudio emits queued/handed-off observations for every frame. Retain one
  # per stage/source/second, so a microphone call keeps later semantic evidence.
  defp add(s, %{name: :playback_observed, source: source, data: data, at_ms: at} = row) do
    key = {source, data[:stage]}

    if not Map.has_key?(s.sampled_at, key) or at - s.sampled_at[key] >= 1_000 do
      append(%{s | sampled_at: Map.put(s.sampled_at, key, at)}, row)
    else
      %{s | sampled_events: s.sampled_events + 1}
    end
  end

  defp add(s, row), do: append(s, row)

  defp append(s, row) do
    if s.count < 12_000 do
      IO.binwrite(s.event_file, JSON.encode!(row) <> "\n")
      %{s | events: [row | s.events], count: s.count + 1}
    else
      %{s | dropped_events: s.dropped_events + 1}
    end
  end

  defp relative(s, at), do: max(0, (at - s.origin) / 1_000)

  defp selected(%{type: :transcript_delta, payload: p}),
    do:
      Map.take(p, [:speaker, :delta, :start_ms, :end_ms, :segment_id, :overlaps_user_segment_id])

  defp selected(%{type: :extension, payload: %{kind: :transcript_discarded} = p}),
    do: Map.take(p, [:kind, :cause, :speaker, :delta, :segment_id])

  defp selected(%{type: :extension, payload: %{kind: :caller_speech} = p}),
    do: Map.take(p, [:kind, :state, :segment_id])

  defp selected(%{type: :task_submitted, payload: %{request: r}}),
    do: Map.take(r, [:id, :task_id, :task_revision, :input])

  defp selected(%{type: type, payload: p})
       when type in [:request_completed, :request_failed, :stale_result], do: safe_result(p)

  defp selected(%{type: type, payload: %{error: %Parlora.Error{} = error}})
       when type in [:failed, :policy_rejected, :policy_failed, :context_rejected] do
    data = %{error_code: error.code}

    case {error.message, error.details} do
      {"Clarification requires a question and an optional 1–128 byte key", _} ->
        Map.put(data, :error_reason, :invalid_clarification)

      {_, %{reason: reason}} when is_atom(reason) and not is_nil(reason) ->
        Map.put(data, :error_reason, reason)

      _ ->
        data
    end
  end

  defp selected(%{type: :closed, payload: %{reason: reason}}) when is_atom(reason),
    do: %{reason: reason}

  defp selected(%{payload: p}) when is_map(p),
    do: Map.take(p, [:stage, :state, :outcome, :cause, :task_id, :task_revision])

  defp selected(_), do: %{}
  defp safe_result(%{result: result}), do: safe_result(result)

  defp safe_result(p),
    do: Map.take(p, [:request_id, :task_id, :task_revision, :status, :summary, :facts])

  def terminate(_, s) do
    :telemetry.detach(s.id)

    unless s.complete do
      Enum.each(s.files, fn {_, file} -> File.close(file) end)
      File.close(s.event_file)
    end
  end
end
