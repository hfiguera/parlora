defmodule BookingDesk.ReminderReadbackTest do
  use ExUnit.Case, async: true
  alias BookingDesk.{ReminderPolicy, ReminderReadback, Reminders}

  defp current do
    %{
      status: "verify_existing",
      destination: "+12025550188",
      request_id: "opt-in",
      patient: "p_1002",
      original_phone: "2025550188"
    }
  end

  defp snapshot(text) do
    task = %{
      id: "reminder",
      revision: 1,
      status: :completed,
      request_ids: ["opt-in"],
      input: %{operation: "reminder_opt_in", cursor: 10}
    }

    %{
      provider_generation: 0,
      session_id: "test",
      tasks: %{"reminder" => task},
      transcripts: [
        %{speaker: :assistant, delta: text, arrival_order: 11, provider_generation: 0},
        %{speaker: :user, delta: "Yeah, that'd be helpful", arrival_order: 10}
      ]
    }
  end

  defp correction(snapshot, current \\ current(), cursor \\ 10),
    do: ReminderReadback.correction(snapshot, current, snapshot.tasks["reminder"], cursor)

  defp remember(snapshot, scope),
    do: put_in(snapshot.tasks["reminder"][:clarification], %{input: scope})

  test "repeated correct questions are not concatenated into a wrong destination" do
    question = "Can we send the reminder to your cell number ending in zero one eight eight?"
    s = snapshot(question)
    first = Map.put(hd(s.transcripts), :segment_id, "first-reply")
    second = %{first | arrival_order: 12, segment_id: "second-reply"}
    s = %{s | transcripts: [second, first, List.last(s.transcripts)]}

    assert ReminderReadback.verified?(s, current())
    assert correction(s) == nil

    same_reply = %{
      s
      | transcripts: [%{second | segment_id: "first-reply"}, first, List.last(s.transcripts)]
    }

    refute ReminderReadback.verified?(same_reply, current())
    assert {_, _} = correction(same_reply)

    for answer <- ["Yes", "Yep, that's my cell"] do
      consent = %{speaker: :user, delta: answer, arrival_order: 13}
      later = %{s | transcripts: [consent | s.transcripts]}

      assert {:input, %{operation: "reminder_confirm", destination: "+12025550188"}} =
               ReminderPolicy.interpret(later, current(),
                 reminder_judge: fn _ -> {:ok, "confirm_number"} end
               )
    end

    for answer <- ["Yes, if it is free", "No, don't send it"] do
      consent = %{speaker: :user, delta: answer, arrival_order: 13}
      later = %{s | transcripts: [consent | s.transcripts]}

      assert {:clarify, _} =
               ReminderPolicy.interpret(later, current(),
                 reminder_judge: fn _ -> {:ok, "confirm_number"} end
               )
    end
  end

  test "an earlier correct question cannot hide a newer wrong or incomplete readback" do
    s = snapshot("Can we text your cell ending in 0188?")
    first = Map.put(hd(s.transcripts), :segment_id, "first-reply")

    for {text, repair?} <- [
          {"Can we text your cell ending in 4289?", true},
          {"Can we text your cell ending in zero one eight", false},
          {"Can we text your cell ending in 0188 or 4289?", true}
        ] do
      second = %{first | arrival_order: 12, segment_id: "second-reply", delta: text}
      later = %{s | transcripts: [second, first, List.last(s.transcripts)]}
      refute ReminderReadback.verified?(later, current())
      assert match?({_, _}, correction(later)) == repair?
      consent = %{speaker: :user, delta: "Yes", arrival_order: 13}
      later = %{later | transcripts: [consent | later.transcripts]}

      assert {:clarify, _} =
               ReminderPolicy.interpret(later, current(),
                 reminder_judge: fn _ -> {:ok, "confirm_number"} end
               )
    end
  end

  test "a wrong numeric or spoken suffix is corrected without another caller turn" do
    for text <- [
          "Is your cell number ending in 4289 — can we send the reminder there?",
          "Can we text your cell ending in four two eight nine? Your appointment remains booked.",
          "Can we text your cell ending in four two eight nine?"
        ] do
      s = snapshot(text)
      assert {message, input} = correction(s)
      assert Reminders.readback?(message, "0188")
      refute message =~ "4289"
      assert input.reminder_readback.request_id == "opt-in"
      assert input.reminder_readback.provider_generation == 0
      assert input.reminder_readback.after_cursor == 11
      assert correction(remember(s, input)) == nil
    end
  end

  test "correct, incomplete and unrelated questions do not trigger a repair" do
    for text <- [
          "Can we text your cell ending in zero one eight eight?",
          "Is your cell number ending in 428",
          "Would you like a text reminder? Can we send it to your cell ending in zero",
          "Would you like a text reminder? Can we send it to your cell ending in zero one eight",
          "Would you like a text reminder? Can we send it to your cell ending in zero one eight eight?",
          "What cell number should we use?",
          "Would you like a reminder 24 hours before?",
          "Your confirmation number is BD-4289."
        ] do
      assert correction(snapshot(text)) == nil
    end
  end

  test "only a receipt-bound current reminder revision can correct its already consumed caller turn" do
    s = snapshot("Can we text your cell ending in 4289?")

    for status <- ["offered", "scheduled", "declined", "need_number"] do
      assert correction(s, %{current() | status: status}) == nil
    end

    assert correction(s, nil) == nil
    assert correction(s, %{current() | request_id: "other-request"}) == nil
    assert {_, _} = correction(put_in(s.tasks["reminder"].status, :submitted))
    assert correction(put_in(s.tasks["reminder"].status, :failed)) == nil
    assert correction(s, current(), 12) == nil
    assert correction(%{s | provider_generation: 1}) == nil
  end

  test "a corrected question replaces earlier wrong digits but still requires fresh exact consent" do
    s = snapshot("Can we text your cell ending in 4289?")
    {message, scope} = correction(s)
    s = remember(s, scope)

    refute ReminderReadback.verified?(s, current())

    spoken = %{
      s
      | transcripts: [%{speaker: :assistant, delta: message, arrival_order: 12} | s.transcripts]
    }

    assert ReminderReadback.verified?(spoken, current())

    s = %{
      s
      | transcripts: [
          %{speaker: :user, delta: "Yep, that's my cell", arrival_order: 13},
          %{speaker: :assistant, delta: message, arrival_order: 12} | s.transcripts
        ]
    }

    opts = [reminder_judge: fn _ -> {:ok, "confirm_number"} end]

    assert {:input, %{operation: "reminder_confirm", destination: "+12025550188"}} =
             ReminderPolicy.interpret(s, current(), opts)

    wrong = snapshot("Can we text your cell ending in 4289?")
    wrong = %{wrong | transcripts: [hd(s.transcripts) | wrong.transcripts]}
    assert {:clarify, _} = ReminderPolicy.interpret(wrong, current(), opts)

    conditional =
      put_in(s.transcripts, [
        %{hd(s.transcripts) | delta: "Yes, if it is free"} | tl(s.transcripts)
      ])

    assert {:clarify, _} = ReminderPolicy.interpret(conditional, current(), opts)
  end

  test "old provider, task and reminder revisions cannot hide a wrong readback" do
    s = snapshot("Can we text your cell ending in 4289?")
    {_, scope} = correction(s)

    for stale <- [
          put_in(scope.reminder_readback.provider_generation, 99),
          put_in(scope.reminder_readback.task_revision, 99),
          put_in(scope.reminder_readback.request_id, "old")
        ] do
      assert {_, _} = correction(remember(s, stale))
    end
  end

  test "new numbers need a complete readback and repeated errors fall back to caller-supplied digits" do
    s = snapshot("Can we text your cell ending in 0188?")
    s = put_in(s.tasks["reminder"].input.operation, "reminder_number")
    current = %{current() | status: "verify_new", destination: "+12025550199"}
    {message, scope} = correction(s, current)
    assert Reminders.readback?(message, current.destination)
    s = remember(s, scope)

    s = %{
      s
      | transcripts: [
          %{
            speaker: :assistant,
            delta: "Can we text your cell ending in 0199?",
            arrival_order: 12
          }
          | s.transcripts
        ]
    }

    assert {question, scope} = correction(s, current)
    assert question =~ "all ten digits"
    assert Reminders.readback_digits(question) == ""
    s = remember(s, scope)
    s = %{s | transcripts: [%{hd(s.transcripts) | arrival_order: 13} | s.transcripts]}
    assert correction(s, current) == nil
  end
end
