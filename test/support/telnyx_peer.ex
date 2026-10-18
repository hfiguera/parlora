defmodule Parlora.TestSupport.TelnyxPeer do
  @moduledoc false
  def handshake(call \\ "call", session \\ "session") do
    [
      %{"event" => "connected", "version" => "1.0.0"},
      %{
        "event" => "start",
        "sequence_number" => "1",
        "stream_id" => "stream",
        "start" => %{
          "call_control_id" => call,
          "call_session_id" => session,
          "media_format" => %{"encoding" => "PCMU", "sample_rate" => 8_000, "channels" => 1}
        }
      }
    ]
  end

  def media(data, chunk \\ 1),
    do: %{
      "event" => "media",
      "stream_id" => "stream",
      "sequence_number" => to_string(chunk + 1),
      "media" => %{
        "track" => "inbound",
        "chunk" => to_string(chunk),
        "timestamp" => to_string((chunk - 1) * 160),
        "payload" => Base.encode64(data)
      }
    }
end
