# Read-only checks of the real readback and intent judges. No booking is executed.
proposal = %{
  id: "probe-proposal",
  revision: 30,
  change: "book",
  slot: "2026-11-05T10:15:00",
  clinician_id: "lee"
}

task = %{
  status: :completed,
  input: %{operation: "propose", cursor: 30, revision: 30},
  request_ids: [proposal.id]
}

base = %{
  proposal: proposal,
  insurance: %{confirmed: true},
  conversation: %{},
  active: %{operation: "propose", date: "2026-11-05", clinician: "lee"},
  appointment: nil,
  reminder: nil,
  pending_request: %{},
  verified_offers: [],
  today: "2026-11-02",
  timezone: "America/Denver"
}

cases = [
  {"recorded acknowledgment", "Yes, please", "'Kay", true},
  {"frustrated explicit approval", nil, "Yes, I already told you", true},
  {"bare acknowledgment", nil, "'Kay", false},
  {"conditional reply", "Yes, please", "Yes, if it is covered", false},
  {"refusal", "Yes, please", "No, don't book it", false},
  {"date correction", "Yes, please", "Actually, November fourth", false}
]

reports =
  Enum.map(cases, fn {name, original, latest, approved?} ->
    parts =
      [
        {:assistant, "Shall I book Thursday, November fifth at 10:15 AM with Dr. Lee?", 31,
         70_000}
      ] ++
        if(original,
          do: [
            {:user, original, 32, 74_000},
            {:assistant, "Okay. Processing that now.", 33, 75_000}
          ],
          else: []
        )

    parts = parts ++ [{:user, latest, 34, 76_800}]

    transcripts =
      for {speaker, text, cursor, start} <- Enum.reverse(parts),
          do: %{
            speaker: speaker,
            delta: text,
            arrival_order: cursor,
            provider_generation: 0,
            start_ms: start,
            end_ms: start + 200
          }

    state =
      Map.merge(base, %{
        latest_user: latest,
        dialogue: Enum.map(parts, fn {speaker, text, _, _} -> %{speaker: speaker, text: text} end)
      })

    snapshot = %Parlora.ContextSnapshot{provider_generation: 0, transcripts: transcripts}
    prepared = BookingDesk.Approval.prepare(snapshot, task, state, approval_continuity: true)
    result = BookingDesk.Judgment.classify(prepared)

    fields =
      case result do
        {:ok, fields} -> fields
        {:incomplete, fields, _} -> fields
        _ -> %{}
      end

    matched =
      match?(
        {:ok,
         %{"intent" => "confirm", "date" => "2026-11-05", "time" => "10:15", "clinician" => "lee"}},
        result
      )

    %{
      case: name,
      intent: fields["intent"],
      continued: Map.has_key?(prepared, :approval_continuation),
      passed: if(approved?, do: matched, else: fields["intent"] != "confirm")
    }
  end)

[output] = System.argv()
report = %{passed: Enum.all?(reports, & &1.passed), cases: reports}
File.write!(output, JSON.encode!(report))
IO.puts(JSON.encode!(report))
unless report.passed, do: System.halt(1)
