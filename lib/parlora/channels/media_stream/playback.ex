defmodule Parlora.Channels.MediaStream.Playback do
  @moduledoc false
  alias Parlora.Error

  defstruct pending: %{},
            bytes: 0,
            capacity: 4_000,
            counter: 0,
            clearing: nil,
            boundary: :twilio_mark

  def admit(%{clearing: clearing}, _frame, _now) when clearing != nil,
    do: Error.tuple(:backpressure, "Media stream clear is awaiting acknowledgment")

  def admit(state, frame, now) do
    bytes = byte_size(frame.data)

    if state.bytes + bytes <= state.capacity do
      record = %{
        stage: :device_reported_playback,
        evidence: :device_report,
        boundary: state.boundary,
        sequence: frame.sequence,
        stream_id: frame.stream_id,
        epoch: frame.playback_epoch,
        bytes: bytes,
        duration_us: frame.duration_us,
        sent_at_us: now
      }

      {name, state} = insert(state, record)
      {:ok, name, %{state | bytes: state.bytes + bytes}}
    else
      Error.tuple(:backpressure, "Media stream unacknowledged playback capacity exhausted")
    end
  end

  def clear(%{clearing: nil} = state, command_id, epoch, now) do
    pending =
      Map.new(state.pending, fn {name, record} ->
        {name, Map.merge(record, %{stage: :unknown, cause: :clear_race})}
      end)

    {name, state} =
      insert(%{state | pending: pending}, %{
        command_id: command_id,
        epoch: epoch,
        sent_at_us: now,
        bytes: 0
      })

    {:ok, name, %{state | clearing: name}}
  end

  def clear(_state, _command_id, _epoch, _now),
    do: Error.tuple(:backpressure, "Another Media stream clear is pending")

  def acknowledge(state, name) do
    case Map.pop(state.pending, name) do
      {nil, _pending} ->
        {:unknown, state}

      {record, pending} ->
        next = %{state | pending: pending, bytes: state.bytes - record.bytes}

        if state.clearing == name,
          do: {:clear, record, %{next | clearing: nil}},
          else: {:playback, record, next}
    end
  end

  def expired?(state, now, timeout_ms),
    do:
      Enum.any?(state.pending, fn {_name, record} ->
        now - record.sent_at_us >= timeout_ms * 1_000
      end)

  defp insert(state, record) do
    name = "parlora-#{state.counter}"
    {name, %{state | counter: state.counter + 1, pending: Map.put(state.pending, name, record)}}
  end
end
