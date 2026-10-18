defmodule Parlora.Providers.OpenAI.Diagnostics do
  @moduledoc false
  # Opt-in and bounded per session. No credentials, prompts, error messages, or
  # assistant audio are retained. PCM and caller captions are sensitive data.
  @max_audio_bytes 2_000_000
  @max_events 4_000
  @max_event_bytes 1_000_000
  @max_text_bytes 262_144

  def new(sink, identity \\ %{})

  def new(sink, identity) when is_pid(sink) do
    %{
      sink: sink,
      identity: Map.take(identity, [:session_id, :adapter_id]),
      received_event_counts: %{},
      last_received_at_us: nil,
      sent_hash: :crypto.hash_init(:sha256),
      origin_us: System.monotonic_time(:microsecond),
      events: [],
      event_count: 0,
      event_bytes: 0,
      omitted_events: 0,
      text_bytes: 0,
      pcm: [],
      captured_audio_bytes: 0,
      sent_audio_bytes: 0,
      accepted_audio_bytes: 0,
      accepted_hash: :crypto.hash_init(:sha256)
    }
  end

  def new(_sink, _identity), do: nil

  def accepted(nil, _pcm), do: nil

  def accepted(trace, pcm) do
    trace = %{
      trace
      | accepted_audio_bytes: trace.accepted_audio_bytes + byte_size(pcm),
        accepted_hash: :crypto.hash_update(trace.accepted_hash, pcm)
    }

    record(trace, %{direction: :accepted, type: "input_audio", bytes: byte_size(pcm)})
  end

  def sent(nil, _command), do: nil

  def sent(trace, %{type: "session.input_audio.append", audio: encoded}) do
    pcm = Base.decode64!(encoded)
    bytes = byte_size(pcm)
    room = max(0, @max_audio_bytes - trace.captured_audio_bytes)
    retained = binary_part(pcm, 0, min(room, bytes))

    trace = %{
      trace
      | pcm: if(retained == "", do: trace.pcm, else: [retained | trace.pcm]),
        sent_hash: :crypto.hash_update(trace.sent_hash, pcm),
        captured_audio_bytes: trace.captured_audio_bytes + byte_size(retained),
        sent_audio_bytes: trace.sent_audio_bytes + bytes
    }

    record(trace, %{direction: :send, type: "session.input_audio.append", bytes: bytes})
  end

  def sent(trace, command),
    do: record(trace, %{direction: :send, type: short(command[:type])})

  def received(nil, _event), do: nil

  def received(trace, event) when is_map(event) do
    type = short(event["type"]) || "unknown"
    trace = count_received(trace, type)

    data = %{
      direction: :receive,
      type: short(event["type"]),
      keys: event |> Map.keys() |> Enum.sort() |> Enum.take(32) |> Enum.map(&short/1)
    }

    data =
      if is_binary(event["type"]) and
           String.starts_with?(event["type"], "session.input_transcript") do
        text = short(event["delta"], 2_048)
        bytes = if is_binary(text), do: byte_size(text), else: 0

        Map.merge(data, %{
          delta: if(trace.text_bytes + bytes <= @max_text_bytes, do: text, else: nil),
          text_omitted: trace.text_bytes + bytes > @max_text_bytes or text != event["delta"],
          start_ms: number(event["start_ms"]),
          end_ms: number(event["end_ms"])
        })
      else
        data
      end

    data =
      case event["error"] do
        %{} = error -> Map.put(data, :provider_error_code, short(error["code"]))
        _other -> data
      end

    record(trace, data)
  end

  def received(trace, _event), do: record(trace, %{direction: :receive, type: "non_object_json"})

  defp count_received(trace, type) do
    # Summaries survive event-ring exhaustion without allowing unbounded keys.
    key =
      if Map.has_key?(trace.received_event_counts, type) or
           map_size(trace.received_event_counts) < 64, do: type, else: "other"

    %{
      trace
      | received_event_counts: Map.update(trace.received_event_counts, key, 1, &(&1 + 1)),
        last_received_at_us: System.monotonic_time(:microsecond) - trace.origin_us
    }
  end

  def finish(nil, _reason), do: nil

  def finish(trace, reason) do
    report = %{
      schema_version: 2,
      identity: trace.identity,
      received_event_counts: trace.received_event_counts,
      last_received_at_us: trace.last_received_at_us,
      origin_us: trace.origin_us,
      finished_at_us: System.monotonic_time(:microsecond),
      reason: reason,
      events: Enum.reverse(trace.events),
      omitted_events: trace.omitted_events,
      captured_event_bytes: trace.event_bytes,
      captured_audio_bytes: trace.captured_audio_bytes,
      sent_audio_bytes: trace.sent_audio_bytes,
      sent_audio_sha256: trace.sent_hash |> :crypto.hash_final() |> Base.encode16(case: :lower),
      audio_truncated: trace.captured_audio_bytes != trace.sent_audio_bytes,
      accepted_audio_bytes: trace.accepted_audio_bytes,
      accepted_audio_sha256:
        trace.accepted_hash |> :crypto.hash_final() |> Base.encode16(case: :lower),
      pcm: trace.pcm |> Enum.reverse() |> IO.iodata_to_binary(),
      delivery_note:
        "Sent means handed to the WebSocket transport, not acknowledged by the server."
    }

    send(trace.sink, {:parlora_provider_diagnostics, report})
    nil
  end

  defp record(%{event_count: count} = trace, _event) when count >= @max_events,
    do: %{trace | omitted_events: trace.omitted_events + 1}

  defp record(trace, event) do
    event = Map.put(event, :at_us, System.monotonic_time(:microsecond) - trace.origin_us)
    text_bytes = if is_binary(event[:delta]), do: byte_size(event.delta), else: 0

    event_bytes = :erlang.external_size(event)

    if trace.event_bytes + event_bytes > @max_event_bytes do
      %{trace | omitted_events: trace.omitted_events + 1}
    else
      %{
        trace
        | events: [event | trace.events],
          event_count: trace.event_count + 1,
          event_bytes: trace.event_bytes + event_bytes,
          text_bytes: trace.text_bytes + text_bytes
      }
    end
  end

  defp short(value, limit \\ 128)
  defp short(value, limit) when is_binary(value), do: String.slice(value, 0, limit)
  defp short(_value, _limit), do: nil
  defp number(value) when is_number(value), do: value
  defp number(_value), do: nil
end
