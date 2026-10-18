defmodule Parlora.OpenAIDiagnosticsTest do
  use ExUnit.Case, async: true
  alias Parlora.Providers.OpenAI.Diagnostics

  test "disabled diagnostics do not retain or emit data" do
    assert nil == Diagnostics.new(nil)
    assert nil == Diagnostics.accepted(nil, "audio")
    assert nil == Diagnostics.sent(nil, %{type: "session.input_audio.append", audio: "invalid"})
    assert nil == Diagnostics.received(nil, %{"type" => "anything"})
    assert nil == Diagnostics.finish(nil, :closed)
    refute_received {:parlora_provider_diagnostics, _}
  end

  test "captures accepted and transmitted audio separately and ignores sensitive fields" do
    pcm = <<1, 2, 3, 4>>

    trace =
      Diagnostics.new(self())
      |> Diagnostics.accepted(pcm)
      |> Diagnostics.sent(%{
        type: "session.start",
        session: %{instructions: "secret prompt"},
        api_key: "secret key"
      })
      |> Diagnostics.sent(%{type: "session.input_audio.append", audio: Base.encode64(pcm)})
      |> Diagnostics.received(%{"type" => "error", "error" => %{"message" => "secret key"}})
      |> Diagnostics.received(%{
        "type" => "session.input_transcript.delta",
        "delta" => " hello",
        "start_ms" => 0,
        "end_ms" => 200
      })
      |> Diagnostics.received(%{
        "type" => "session.input_transcript.future",
        "new_field" => "unknown text"
      })

    assert nil == Diagnostics.finish(trace, :closed)
    assert_receive {:parlora_provider_diagnostics, report}
    assert report.pcm == pcm
    assert report.accepted_audio_bytes == 4
    assert report.accepted_audio_sha256 == Base.encode16(:crypto.hash(:sha256, pcm), case: :lower)
    assert report.sent_audio_bytes == 4
    refute report.audio_truncated
    assert Enum.any?(report.events, &(&1[:delta] == " hello"))
    assert List.last(report.events).keys == ["new_field", "type"]
    refute inspect(report) =~ "secret"
    refute inspect(report) =~ "unknown text"
  end

  test "identity, full-stream hashes and received counters survive bounded event storage" do
    trace = Diagnostics.new(self(), %{session_id: "call", adapter_id: "provider", secret: "omit"})

    trace =
      Enum.reduce(1..4_100, trace, fn _, t ->
        t
        |> Diagnostics.sent(%{type: "session.input_audio.append", audio: Base.encode64(<<1, 0>>)})
        |> Diagnostics.received(%{
          "type" => "session.output_audio.delta",
          "delta" => "not retained"
        })
      end)

    Diagnostics.finish(trace, :closed)
    assert_receive {:parlora_provider_diagnostics, report}
    assert report.identity == %{session_id: "call", adapter_id: "provider"}
    assert report.received_event_counts["session.output_audio.delta"] == 4_100

    assert report.sent_audio_sha256 ==
             Base.encode16(:crypto.hash(:sha256, :binary.copy(<<1, 0>>, 4_100)), case: :lower)

    assert report.last_received_at_us >= 0
    assert report.omitted_events > 0
    refute inspect(report) =~ "not retained"
  end

  test "capture has hard bounds and exposes truncation" do
    chunk = :binary.copy(<<1, 2>>, 1000)
    command = %{type: "session.input_audio.append", audio: Base.encode64(chunk)}

    trace =
      Enum.reduce(1..4500, Diagnostics.new(self()), fn _, trace ->
        Diagnostics.sent(trace, command)
      end)

    Diagnostics.finish(trace, :terminated)
    assert_receive {:parlora_provider_diagnostics, report}
    assert byte_size(report.pcm) == 2_000_000
    assert report.sent_audio_bytes == 9_000_000
    assert report.audio_truncated
    assert Enum.count_until(report.events, 4001) == 4000
    assert report.omitted_events == 500
  end
end
