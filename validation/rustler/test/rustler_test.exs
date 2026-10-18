defmodule RustlerBoundaryTest do
  use ExUnit.Case

  test "fault hooks are disabled during ordinary use" do
    assert_raise ArgumentError, fn -> OpusProbe.inject_panic() end
    assert_raise ArgumentError, fn -> OpusProbe.inject_abort() end
  end

  test "Rust term decoding rejects invalid resource and binary arguments" do
    assert_raise ArgumentError, fn -> OpusProbe.close(make_ref()) end
    assert_raise ArgumentError, fn -> OpusProbe.new(:encoder, 24_000, 1, :voip) end
    {:ok, codec} = OpusProbe.new(:encoder, 24_000, 1, 2048)
    assert_raise ArgumentError, fn -> OpusProbe.encode(codec, [0, 1], 480) end
    assert_raise ArgumentError, fn -> OpusProbe.encode(codec, <<0>>, Integer.pow(2, 100)) end
    assert :ok = OpusProbe.close(codec)
  end
end
