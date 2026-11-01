defmodule Parlora.AudioObserverTest do
  use ExUnit.Case, async: true

  test "raw audio diagnostics are opt-in and bounded even when receiver stops draining" do
    credits = :atomics.new(2, [])
    observer = %{pid: self(), credits: credits}
    assert :ok = Parlora.AudioObserver.send_audio(nil, :input, <<1, 0>>)
    refute_received {:parlora_audio, _, _, _}
    for _ <- 1..300, do: Parlora.AudioObserver.send_audio(observer, :output, <<1, 0>>)
    assert :atomics.get(credits, 1) == 256
    assert :atomics.get(credits, 2) == 44
    assert_received {:parlora_audio, :output, at, <<1, 0>>}
    assert is_integer(at)
    :atomics.sub(credits, 1, 1)
    Parlora.AudioObserver.send_audio(observer, :output, <<2, 0>>)
    assert_received {:parlora_audio, :output, _, <<2, 0>>}
  end
end
