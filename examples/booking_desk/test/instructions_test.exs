defmodule BookingDesk.InstructionsTest do
  use ExUnit.Case, async: true

  test "GPT-Live receives native client-handoff guidance without leaking its token to tool providers" do
    openai = BookingDesk.instructions("openai")
    assert String.starts_with?(openai, BookingDesk.instructions())
    assert openai =~ "Generate <|SpawnThinking|> when:"
    assert openai =~ "Do not generate <|SpawnThinking|> when:"

    for provider <- ["gemini", "phonic"] do
      assert BookingDesk.instructions(provider) == BookingDesk.instructions()
      refute BookingDesk.instructions(provider) =~ "<|SpawnThinking|>"
    end
  end

  test "Grok receives structured conversational wording with the shared clinic safeguards" do
    prompt = BookingDesk.instructions("grok")
    headings = Regex.scan(~r/^## .+$/m, prompt) |> List.flatten()

    assert headings == [
             "## Role & Persona",
             "## Objective",
             "## Conversation Flow",
             "## Guardrails & Escalation",
             "## Voice & Communication Style"
           ]

    refute prompt =~ "<|SpawnThinking|>"
    assert prompt =~ "complete conversational sentences"
    assert prompt =~ "A short acknowledgment is optional"
    assert prompt =~ "Do not narrate internal tool or database steps"
    refute prompt =~ "Keep replies to one or two short sentences"

    for rule <- [
          "Never retry a booking automatically",
          "A slot choice is not confirmation",
          "delegate BEFORE speaking any number",
          "A stored number is not consent",
          "Reminder consent is separate from booking approval",
          "Use confirmation_spoken exactly",
          "Never delay this for registration",
          "Never announce an obsolete result",
          "Do not claim insurance eligibility",
          "Never submit another booking to correct a code"
        ] do
      assert BookingDesk.instructions() =~ rule
      assert prompt =~ rule
    end
  end
end
