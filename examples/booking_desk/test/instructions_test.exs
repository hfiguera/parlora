defmodule BookingDesk.InstructionsTest do
  use ExUnit.Case, async: true

  test "GPT-Live-1.1 uses plain-language handoffs while rollback retains the 1.0 token" do
    openai = BookingDesk.instructions("openai")
    assert String.starts_with?(openai, BookingDesk.instructions())
    assert openai =~ "Delegate to the backend when:"
    assert openai =~ "Do not delegate when:"
    assert openai =~ "Backchannel policy:"
    assert openai =~ "Interruption policy:"

    assert openai =~
             "Do not say a booking is processing or submitted unless the application reports that state."

    assert openai =~
             "Do not say you are scheduling or saving a reminder until the application confirms that action."

    refute openai =~ "<|SpawnThinking|>"

    assert BookingDesk.instructions("openai", model: "gpt-live-1.1") == openai
    legacy = BookingDesk.instructions("openai", model: "gpt-live-1")
    assert legacy =~ "Generate <|SpawnThinking|> when:"
    assert legacy =~ "Do not generate <|SpawnThinking|> when:"

    for prompt <- [openai, legacy],
        rule <- [
          "explicitly approves the current proposal",
          "Do not guess results while waiting",
          "Never retry a booking automatically",
          "A stored number is not consent"
        ] do
      assert prompt =~ rule
    end

    for provider <- ["gemini", "phonic", "prism"] do
      assert BookingDesk.instructions(provider) == BookingDesk.instructions()
      refute BookingDesk.instructions(provider) =~ "<|SpawnThinking|>"
    end

    for provider <- ~w(gemini grok phonic prism), model <- ["gpt-live-1", "gpt-live-1.1"] do
      assert BookingDesk.instructions(provider, model: model) ==
               BookingDesk.instructions(provider)
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

  test "every provider describes a date correction as an availability search" do
    for provider <- ~w(openai gemini grok phonic prism) do
      prompt = BookingDesk.instructions(provider)
      assert prompt =~ "delegate a search for openings on the new date"
      assert prompt =~ ~s(say "Sure, one moment" or wait)
      assert prompt =~ "Once the revised availability arrives, lead with the verified options."
      assert prompt =~ "start your next reply by naming its month and day"
      assert prompt =~ "do not repeat the offer or the booking receipt"

      assert prompt =~
               "Reserve cancellation and rescheduling language for explicit requests to change an existing booked appointment."
    end
  end
end
