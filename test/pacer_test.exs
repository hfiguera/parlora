defmodule Parlora.PacerTest do
  use ExUnit.Case, async: true
  alias Parlora.Pacer

  test "fractional-millisecond media durations accumulate without truncation or timer drift" do
    # 95 bytes of μ-law represent 11,875 microseconds, not 11 milliseconds.
    assert {21_875, 12} = Pacer.next(10_000, 11_875, 10_500)
    assert {33_750, 11} = Pacer.next(21_875, 11_875, 23_000)
    assert {45_625, 11} = Pacer.next(33_750, 11_875, 35_000)
    assert {100_000, 1} = Pacer.next(45_625, 11_875, 100_000)
  end
end
