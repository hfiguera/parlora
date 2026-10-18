defmodule Parlora.TwilioProtocolTest do
  use ExUnit.Case, async: true
  alias Parlora.Channels.Twilio.Protocol

  @account "AC11111111111111111111111111111111"
  @call "CA22222222222222222222222222222222"
  @stream "MZ33333333333333333333333333333333"

  test "handshake binds account, call, stream and the exact bidirectional format" do
    connecting = Protocol.new(@account, @call)
    assert {:error, _error} = Protocol.receive_message(connecting, start())
    starting = connected(connecting)

    for {path, value} <- [
          {["start", "accountSid"], "AC" <> String.duplicate("0", 32)},
          {["start", "callSid"], "CA" <> String.duplicate("0", 32)},
          {["start", "streamSid"], "MZ" <> String.duplicate("0", 32)},
          {["start", "mediaFormat", "sampleRate"], 24_000},
          {["start", "mediaFormat", "encoding"], "audio/pcm"},
          {["start", "tracks"], ["outbound"]}
        ] do
      assert {:error, _error} = Protocol.receive_message(starting, put_in(start(), path, value))
    end

    assert {:ok, :started, ready} = Protocol.receive_message(starting, start())
    assert ready.stream_sid == @stream
    assert {:duplicate, ^ready} = Protocol.receive_message(ready, start())
  end

  test "media remains ordered, bounded and timestamped independently of playback marks" do
    ready = ready()
    data = :binary.copy(<<128>>, 160)
    assert {:ok, {:audio, ^data, 0, false}, next} = Protocol.receive_message(ready, media(data))
    assert {:duplicate, ^next} = Protocol.receive_message(next, media(data))

    mark = %{
      "event" => "mark",
      "sequenceNumber" => "3",
      "streamSid" => @stream,
      "mark" => %{"name" => "m"}
    }

    assert {:ok, {:mark, "m"}, next} = Protocol.receive_message(next, mark)

    second =
      media(<<255>>)
      |> Map.put("sequenceNumber", "4")
      |> put_in(["media", "chunk"], "2")
      |> put_in(["media", "timestamp"], "20")

    assert {:ok, {:audio, <<255>>, 20_000, false}, _next} = Protocol.receive_message(next, second)

    assert {:error, _error} =
             Protocol.receive_message(ready, Map.put(media(data), "sequenceNumber", "3"))

    assert {:error, _error} = Protocol.receive_message(ready, media(:binary.copy(<<0>>, 1_601)))

    assert {:error, _error} =
             Protocol.receive_message(ready, put_in(media(data), ["media", "payload"], "!"))

    assert {:error, _error} =
             Protocol.receive_message(ready, Map.put(media(data), "streamSid", "other"))
  end

  test "stop closes this stream and prevents subsequent media" do
    stop = %{
      "event" => "stop",
      "sequenceNumber" => "2",
      "streamSid" => @stream,
      "stop" => %{"accountSid" => @account, "callSid" => @call}
    }

    assert {:ok, :stopped, closed} = Protocol.receive_message(ready(), stop)
    assert {:error, _error} = Protocol.receive_message(closed, media(<<255>>))
  end

  defp ready do
    {:ok, :started, state} =
      Protocol.new(@account, @call) |> connected() |> Protocol.receive_message(start())

    state
  end

  defp connected(state) do
    {:ok, :connected, state} =
      Protocol.receive_message(state, %{
        "event" => "connected",
        "protocol" => "Call",
        "version" => "1.0.0"
      })

    state
  end

  defp start do
    %{
      "event" => "start",
      "sequenceNumber" => "1",
      "streamSid" => @stream,
      "start" => %{
        "accountSid" => @account,
        "callSid" => @call,
        "streamSid" => @stream,
        "tracks" => ["inbound"],
        "mediaFormat" => %{"encoding" => "audio/x-mulaw", "sampleRate" => 8_000, "channels" => 1}
      }
    }
  end

  defp media(data) do
    %{
      "event" => "media",
      "sequenceNumber" => "2",
      "streamSid" => @stream,
      "media" => %{
        "track" => "inbound",
        "chunk" => "1",
        "timestamp" => "0",
        "payload" => Base.encode64(data)
      }
    }
  end
end
