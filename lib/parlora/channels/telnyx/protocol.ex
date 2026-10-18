defmodule Parlora.Channels.Telnyx.Protocol do
  @moduledoc false
  alias Parlora.Channels.MediaStream.Wire
  alias Parlora.Error

  defstruct [
    :call_control_id,
    :call_session_id,
    :stream_id,
    status: :connecting,
    next_chunk: nil,
    pending: %{},
    bytes: 0,
    capacity: 1_600,
    reorder_us: 40_000,
    seen: []
  ]

  def init(options, limits) do
    %__MODULE__{
      call_control_id: Keyword.fetch!(options, :call_control_id),
      call_session_id: Keyword.fetch!(options, :call_session_id),
      capacity: limits.audio_queue_bytes,
      reorder_us: Keyword.get(options, :reorder_ms, 40) * 1_000
    }
  end

  def valid_options?(options) do
    reorder = Keyword.get(options, :reorder_ms, 40)

    id?(Keyword.get(options, :call_control_id)) and id?(Keyword.get(options, :call_session_id)) and
      is_integer(reorder) and reorder in 1..200
  end

  def owner_tag, do: :parlora_telnyx
  def mark_boundary, do: :telnyx_mark
  def minimum_packet_bytes, do: 160
  def stream_id(state), do: state.stream_id

  def receive_message(%{status: :connecting} = state, %{
        "event" => "connected",
        "version" => "1.0.0"
      }),
      do: {:ok, :connected, %{state | status: :starting}}

  def receive_message(state, %{"event" => "error", "payload" => %{"code" => code}})
      when is_integer(code) and state.status in [:starting, :streaming],
      do: invalid({:remote_error, code})

  def receive_message(%{status: status} = state, %{"sequence_number" => sequence} = message)
      when status in [:starting, :streaming] do
    with {:ok, number} <- Wire.number(sequence) do
      if number in state.seen do
        {:duplicate, state}
      else
        dispatch(%{state | seen: Enum.take([number | state.seen], 128)}, message)
      end
    end
  end

  def receive_message(_state, _message), do: invalid(:unexpected_message)

  def media(_stream, data), do: %{event: "media", media: %{payload: Base.encode64(data)}}
  def mark(_stream, name), do: %{event: "mark", mark: %{name: name}}
  def clear(_stream), do: %{event: "clear"}

  def flush(%{pending: pending} = state, _now) when map_size(pending) == 0, do: {[], state}

  def flush(state, now) do
    oldest = state.pending |> Map.values() |> Enum.map(& &1.arrived_at) |> Enum.min()

    cond do
      state.next_chunk != nil and Map.has_key?(state.pending, state.next_chunk) ->
        drain(state, false, [])

      now - oldest < state.reorder_us ->
        {[], state}

      true ->
        next = state.pending |> Map.keys() |> Enum.min()
        discontinuity = state.next_chunk != nil
        drain(%{state | next_chunk: next}, discontinuity, [])
    end
  end

  defp dispatch(
         %{status: :starting, call_control_id: call, call_session_id: session} = state,
         %{
           "event" => "start",
           "stream_id" => stream,
           "start" => %{
             "call_control_id" => call,
             "call_session_id" => session,
             "media_format" => %{"encoding" => "PCMU", "sample_rate" => 8_000, "channels" => 1}
           }
         }
       ) do
    if id?(stream),
      do: {:ok, :started, %{state | status: :streaming, stream_id: stream}},
      else: invalid(:invalid_identity)
  end

  defp dispatch(
         %{status: :streaming, stream_id: stream} = state,
         %{"event" => "media", "stream_id" => stream, "media" => media}
       ),
       do: receive_media(state, media)

  defp dispatch(
         %{status: :streaming, stream_id: stream} = state,
         %{"event" => "mark", "stream_id" => stream, "mark" => %{"name" => name}}
       )
       when is_binary(name) and byte_size(name) in 1..128,
       do: {:ok, {:mark, name}, state}

  defp dispatch(
         %{status: :streaming, stream_id: stream, call_control_id: call} = state,
         %{"event" => "stop", "stream_id" => stream, "stop" => %{"call_control_id" => call}}
       ),
       do: {:ok, :stopped, %{state | status: :stopped, pending: %{}, bytes: 0}}

  defp dispatch(
         %{status: :streaming, stream_id: stream} = state,
         %{"event" => "dtmf", "stream_id" => stream, "dtmf" => %{"digit" => digit}}
       )
       when digit in ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "#"],
       do: {:ok, :dtmf, state}

  defp dispatch(_state, _message), do: invalid(:invalid_message)

  defp receive_media(
         state,
         %{"track" => "inbound", "chunk" => chunk, "timestamp" => time, "payload" => encoded}
       )
       when is_binary(encoded) do
    with {:ok, chunk} <- Wire.number(chunk),
         {:ok, timestamp} <- Wire.number(time),
         true <- byte_size(encoded) <= 4 * div(state.capacity + 2, 3),
         {:ok, data} <- Base.decode64(encoded),
         true <- byte_size(data) in 1..state.capacity do
      insert(state, chunk, timestamp, data)
    else
      _invalid -> invalid(:invalid_media)
    end
  end

  defp receive_media(_state, _media), do: invalid(:invalid_media)

  defp insert(state, chunk, timestamp, data) do
    cond do
      (state.next_chunk != nil and chunk < state.next_chunk) or Map.has_key?(state.pending, chunk) ->
        {:duplicate, state}

      state.bytes + byte_size(data) > state.capacity or map_size(state.pending) >= 64 ->
        invalid(:reorder_overflow)

      true ->
        now = System.monotonic_time(:microsecond)
        entry = %{data: data, timestamp: timestamp, arrived_at: now}

        state = %{
          state
          | pending: Map.put(state.pending, chunk, entry),
            bytes: state.bytes + byte_size(data)
        }

        {events, state} = flush(state, now)
        {:ok, {:audio_batch, events}, state}
    end
  end

  defp drain(state, discontinuity, events) do
    case Map.pop(state.pending, state.next_chunk) do
      {nil, _pending} ->
        {Enum.reverse(events), state}

      {entry, pending} ->
        event = {:audio, entry.data, entry.timestamp, discontinuity}

        state = %{
          state
          | pending: pending,
            bytes: state.bytes - byte_size(entry.data),
            next_chunk: state.next_chunk + 1
        }

        drain(state, false, [event | events])
    end
  end

  defp id?(value), do: is_binary(value) and byte_size(value) in 1..512

  defp invalid(reason),
    do: {:error, Error.new(:invalid_argument, "Invalid Telnyx stream message", %{reason: reason})}
end
