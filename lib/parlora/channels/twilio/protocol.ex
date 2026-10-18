defmodule Parlora.Channels.Twilio.Protocol do
  @moduledoc false
  alias Parlora.Channels.MediaStream.Wire
  alias Parlora.Error

  defstruct [
    :account_sid,
    :call_sid,
    :stream_sid,
    status: :connecting,
    sequence: 0,
    chunk: 0,
    next_timestamp_us: nil,
    max_media_bytes: 1_600
  ]

  def init(options, limits),
    do:
      new(
        Keyword.fetch!(options, :account_sid),
        Keyword.fetch!(options, :call_sid),
        limits.audio_queue_bytes
      )

  def valid_options?(options),
    do:
      sid?(Keyword.get(options, :account_sid), "AC") and
        sid?(Keyword.get(options, :call_sid), "CA")

  def owner_tag, do: :parlora_twilio
  def mark_boundary, do: :twilio_mark
  def minimum_packet_bytes, do: 0
  def stream_id(state), do: state.stream_sid
  def flush(state, _now), do: {[], state}

  def new(account, call, max_media_bytes \\ 1_600) do
    %__MODULE__{account_sid: account, call_sid: call, max_media_bytes: max_media_bytes}
  end

  def receive_message(
        %{status: :connecting} = state,
        %{"event" => "connected", "protocol" => "Call", "version" => "1.0.0"}
      ),
      do: {:ok, :connected, %{state | status: :starting}}

  def receive_message(%{status: status} = state, %{"sequenceNumber" => raw} = message)
      when status in [:starting, :streaming] do
    with {:ok, sequence} <- Wire.number(raw) do
      cond do
        sequence <= state.sequence -> {:duplicate, state}
        sequence != state.sequence + 1 -> invalid(:sequence_gap)
        true -> dispatch(%{state | sequence: sequence}, message)
      end
    end
  end

  def receive_message(_state, _message), do: invalid(:unexpected_message)

  def sid?(sid, prefix) when is_binary(sid) do
    byte_size(sid) == 34 and String.starts_with?(sid, prefix) and
      String.match?(binary_part(sid, 2, 32), ~r/\A[0-9a-fA-F]{32}\z/)
  end

  def sid?(_sid, _prefix), do: false

  def media(stream, audio),
    do: %{event: "media", streamSid: stream, media: %{payload: Base.encode64(audio)}}

  def mark(stream, name), do: %{event: "mark", streamSid: stream, mark: %{name: name}}
  def clear(stream), do: %{event: "clear", streamSid: stream}

  defp dispatch(
         %{status: :starting, account_sid: account, call_sid: call} = state,
         %{
           "event" => "start",
           "streamSid" => stream,
           "start" => %{
             "accountSid" => account,
             "callSid" => call,
             "streamSid" => stream,
             "tracks" => ["inbound"],
             "mediaFormat" => %{
               "encoding" => "audio/x-mulaw",
               "sampleRate" => 8_000,
               "channels" => 1
             }
           }
         }
       ) do
    if sid?(account, "AC") and sid?(call, "CA") and sid?(stream, "MZ"),
      do: {:ok, :started, %{state | status: :streaming, stream_sid: stream}},
      else: invalid(:invalid_identity)
  end

  defp dispatch(
         %{status: :streaming, stream_sid: stream} = state,
         %{"event" => "media", "streamSid" => stream, "media" => media}
       ),
       do: receive_media(state, media)

  defp dispatch(
         %{status: :streaming, stream_sid: stream} = state,
         %{"event" => "mark", "streamSid" => stream, "mark" => %{"name" => name}}
       )
       when is_binary(name) and byte_size(name) in 1..128,
       do: {:ok, {:mark, name}, state}

  defp dispatch(
         %{status: :streaming, stream_sid: stream, account_sid: account, call_sid: call} = state,
         %{
           "event" => "stop",
           "streamSid" => stream,
           "stop" => %{"accountSid" => account, "callSid" => call}
         }
       ),
       do: {:ok, :stopped, %{state | status: :stopped}}

  defp dispatch(
         %{status: :streaming, stream_sid: stream} = state,
         %{
           "event" => "dtmf",
           "streamSid" => stream,
           "dtmf" => %{"track" => "inbound_track", "digit" => digit}
         }
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
         {:ok, timestamp_ms} <- Wire.number(time),
         true <- chunk == state.chunk + 1,
         true <- byte_size(encoded) <= 4 * div(state.max_media_bytes + 2, 3),
         {:ok, data} <- Base.decode64(encoded),
         true <- byte_size(data) in 1..state.max_media_bytes do
      timestamp_us = timestamp_ms * 1_000
      discontinuity = state.next_timestamp_us != nil and state.next_timestamp_us != timestamp_us

      {:ok, {:audio, data, timestamp_us, discontinuity},
       %{state | chunk: chunk, next_timestamp_us: timestamp_us + byte_size(data) * 125}}
    else
      _invalid -> invalid(:invalid_media)
    end
  end

  defp receive_media(_state, _media), do: invalid(:invalid_media)

  defp invalid(reason),
    do: {:error, Error.new(:invalid_argument, "Invalid Twilio stream message", %{reason: reason})}
end
