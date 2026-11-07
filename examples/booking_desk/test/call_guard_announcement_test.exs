defmodule BookingDesk.CallGuard.AnnouncementTest do
  use ExUnit.Case, async: true
  alias BookingDesk.CallGuard
  alias BookingDesk.CallGuard.Announcement

  defp caption(message, text, segment \\ "reply", generation \\ 0),
    do:
      Announcement.caption(message, %Parlora.Event{
        generation: generation,
        payload: %{delta: text, segment_id: segment}
      })

  test "a number question and its audio cannot acknowledge an unrelated scope message" do
    message = Announcement.new(:scope_redirect, CallGuard.message(:scope_redirect), 0, 0)
    message = caption(message, "Can we send the reminder to the number ending in 0188?")
    message = Announcement.audible(message, 100)
    refute message.caption
    refute message.heard
    assert message.last_voice == 100
  end

  test "only the intended words in one generation and reply can establish caption evidence" do
    expected = CallGuard.message(:scope_redirect)
    message = Announcement.new(:scope_redirect, expected, 0, 0)
    {first, last} = String.split_at(expected, 30)
    partial = caption(message, first)
    refute caption(partial, last, "different").caption
    refute caption(message, expected, "reply", 1).caption
    refute caption(message, "I will not say " <> expected).caption
    matched = caption(partial, last)
    assert matched.caption
    refute matched.heard
    assert Announcement.audible(matched, 100).heard
    refute Announcement.reset(matched).caption
  end

  test "punctuation, case and explicit emergency number renderings preserve exact message evidence" do
    expected = CallGuard.message(:emergency)
    message = Announcement.new(:emergency, expected, 0, 0)
    spoken = expected |> String.upcase() |> String.replace("911", "NINE ONE ONE")
    assert caption(message, spoken).caption
    refute caption(message, "Goodbye.").caption
  end

  test "nonverbal annotations do not change the spoken closing message" do
    expected = CallGuard.message(:scope_close)
    message = Announcement.new(:scope_close, expected, 0, 0)
    partial = caption(message, " [s")
    assert caption(partial, "igh] [breath] " <> expected).caption
  end

  test "a brief acknowledgment can precede a scope message" do
    for reason <- [:scope_redirect, :scope_close] do
      expected = CallGuard.message(reason)
      message = Announcement.new(reason, expected, 0, 0)
      assert caption(message, "Sure. " <> expected).caption
      assert caption(message, "Mm. Right. " <> expected).caption
      refute caption(message, "Sure. I will not say " <> expected).caption
    end
  end
end
