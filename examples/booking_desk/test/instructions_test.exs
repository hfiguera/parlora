defmodule BookingDesk.InstructionsTest do
  use ExUnit.Case, async: true

  test "GPT-Live receives native client-handoff guidance without leaking its token to tool providers" do
    openai = BookingDesk.instructions("openai")
    assert String.starts_with?(openai, BookingDesk.instructions())
    assert openai =~ "Generate <|SpawnThinking|> when:"
    assert openai =~ "Do not generate <|SpawnThinking|> when:"

    for provider <- ["gemini", "grok", "phonic"] do
      assert BookingDesk.instructions(provider) == BookingDesk.instructions()
      refute BookingDesk.instructions(provider) =~ "<|SpawnThinking|>"
    end
  end
end
