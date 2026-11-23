# Read-only JEV checks for the recorded caller's follow-ups. No speech session,
# booking operation, patient lookup, or reminder action is executed.
base = %{
  confirmation_recovery: true,
  proposal: nil,
  insurance: %{confirmed: true},
  active: %{operation: "confirm", date: "2026-11-05", clinician: "lee"},
  appointment: %{kind: "booking", status: "booked", slot: "2026-11-05T10:15:00"},
  reminder: %{status: "offered"},
  conversation: %{},
  pending_request: %{},
  verified_offers: [],
  today: "2026-11-02",
  timezone: "America/Denver"
}

cases = [
  {"I was waiting for the confirmation from you", ~w(progress repeat)},
  {"Is booked it", ~w(progress)},
  {"Repeat that", ~w(repeat)},
  {"Thank you", ~w(none)},
  {"Cancel my booked appointment", ~w(cancel)}
]

reports =
  Enum.map(cases, fn {text, expected} ->
    state =
      Map.merge(base, %{
        latest_user: text,
        dialogue: [
          %{speaker: :assistant, text: "You're booked for"},
          %{speaker: :user, text: "Q-restirichekin"},
          %{speaker: :assistant, text: BookingDesk.CallGuard.message(:clarify_scope)},
          %{speaker: :user, text: text}
        ]
      })

    result = BookingDesk.Judgment.classify(state)

    intent =
      case result do
        {:ok, %{"intent" => intent}} -> intent
        {:incomplete, %{"intent" => intent}, _} -> intent
        _ -> nil
      end

    %{text: text, expected: expected, intent: intent, passed: intent in expected}
  end)

report = %{passed: Enum.all?(reports, & &1.passed), cases: reports}
[output] = System.argv()
File.write!(output, JSON.encode!(report))
IO.puts(JSON.encode!(report))
unless report.passed, do: System.halt(1)
