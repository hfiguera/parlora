# Compare the non-OpenAI configuration and unscoped reminder decisions with the
# committed approval fix. No provider connection, database write or message send.
Code.compiler_options(ignore_module_conflict: true)

for {path, original, baseline} <- [
      {"examples/booking_desk/lib/booking_desk.ex", "BookingDesk",
       "BookingDeskBeforeReminderFix"},
      {"examples/booking_desk/lib/booking_desk/reminder_policy.ex", "BookingDesk.ReminderPolicy",
       "BookingDesk.ReminderPolicyBeforeFix"}
    ] do
  {source, 0} = System.cmd("git", ["show", "82a2dc8:" <> path])

  Code.compile_string(
    String.replace(source, "defmodule #{original} do", "defmodule #{baseline} do")
  )
end

for provider <- ~w(gemini grok phonic prism) do
  true = BookingDesk.instructions(provider) == BookingDeskBeforeReminderFix.instructions(provider)

  true =
    BookingDesk.provider_options(provider) ==
      BookingDeskBeforeReminderFix.provider_options(provider)

  true =
    BookingDesk.assistant_voice(provider) ==
      BookingDeskBeforeReminderFix.assistant_voice(provider)

  true = BookingDesk.limits(provider) == BookingDeskBeforeReminderFix.limits(provider)
end

questions = [
  "Would you like a text reminder?",
  "Can we send it to the number ending in 0188?",
  "Great, one moment. Can we send it to the number ending in zero one eight eight?",
  "Can we send it to 4289?",
  "Can we send it to two zero two five five five zero one eight eight?"
]

answers = [
  "Yes, please",
  "Yep, that's my cell",
  "188? Yes, do it",
  "188",
  "Yes, if it is free",
  "No, don't send it",
  "My new number is 2025550199",
  "I'm not sure"
]

results =
  for status <- ~w(offered verify_existing verify_new),
      question <- questions,
      answer <- answers,
      intent <- ~w(opt_in confirm_number number change decline none unclear appointment) do
    snapshot = %{
      session_id: "provider-comparison",
      provider_generation: 0,
      transcripts: [
        %{speaker: :user, delta: answer, arrival_order: 2},
        %{speaker: :assistant, delta: question, arrival_order: 1}
      ]
    }

    current = %{status: status, destination: "+12025550188", patient: "p_1002"}

    opts = [
      reminder_judge: fn _ -> {:ok, intent} end,
      phone_extractor: fn _ -> {:incomplete, [:phone]} end
    ]

    before = BookingDesk.ReminderPolicyBeforeFix.interpret(snapshot, current, opts)
    after_fix = BookingDesk.ReminderPolicy.interpret(snapshot, current, opts)

    if before != after_fix,
      do:
        raise(
          "Changed unscoped reminder decision: #{inspect({status, question, answer, intent})}"
        )

    true
  end

IO.puts(
  JSON.encode!(%{
    provider_configurations_unchanged: 4,
    reminder_decisions_unchanged: length(results)
  })
)
