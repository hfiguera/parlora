defmodule BookingDesk.ReminderPolicyTest do
  use ExUnit.Case, async: true
  alias BookingDesk.ReminderPolicy

  test "native acknowledgments cannot supply consent or hide conditions on the caller's answer" do
    current = %{
      status: "verify_existing",
      destination: "+12025550188",
      patient: "p",
      original_phone: "2025550188"
    }

    opts = [
      reminder_judge: fn _ -> {:ok, "confirm_number"} end,
      phone_extractor: fn _ -> {:incomplete, [:phone]} end
    ]

    for {question, first, last, expected} <- [
          {"Can we send the reminder to 0188?", "Yes, ", "please", :allow},
          {"Can we send the reminder to 0188?", "Yes, ", "if it is free", :deny},
          {"Can we send the reminder to 0188?", "Yes, ", "but don't send it", :deny},
          {"Can we send the reminder to 4289?", "Yes, ", "please", :deny},
          {"Is 0188 your cell?", "Yes, ", "please", :allow}
        ] do
      s = snapshot(question, last)

      s = %{
        s
        | transcripts: [
            %{speaker: :user, delta: last, segment_id: "caller", arrival_order: 4},
            %{
              speaker: :assistant,
              delta: "Mm-hmm.",
              segment_id: "ack",
              overlaps_user_segment_id: "caller",
              arrival_order: 3
            },
            %{speaker: :user, delta: first, segment_id: "caller", arrival_order: 2},
            %{speaker: :assistant, delta: question, segment_id: "question", arrival_order: 1}
          ]
      }

      case expected do
        :allow ->
          assert {:input, %{operation: "reminder_confirm", destination: "+12025550188"}} =
                   ReminderPolicy.interpret(s, current, opts)

        :deny ->
          result = ReminderPolicy.interpret(s, current, opts)
          assert match?({:clarify, _}, result), inspect({question, first, last, result})
      end
    end

    s = snapshot("Can we send the reminder to 0188?", "I'm not sure")

    acknowledgment = %{
      speaker: :assistant,
      delta: "Yes, please",
      segment_id: "ack",
      overlaps_user_segment_id: "caller",
      arrival_order: 3
    }

    caller = Map.put(hd(s.transcripts), :segment_id, "caller")

    assert {:clarify, _} =
             ReminderPolicy.interpret(
               %{s | transcripts: [acknowledgment, caller, List.last(s.transcripts)]},
               current,
               opts
             )
  end

  defp snapshot(question, answer) do
    %{
      session_id: "test",
      provider_generation: 1,
      transcripts: [
        %{speaker: :user, delta: answer, arrival_order: 2},
        %{speaker: :assistant, delta: question, arrival_order: 1}
      ]
    }
  end

  test "simple consent to an exact reminder offer opts in without inventing number consent" do
    state = %{status: "offered", patient: "p", original_phone: "2025550188"}

    opts = [
      reminder_judge: fn _ -> flunk("an exact reminder offer and simple yes need no model") end
    ]

    for offer <- [
          "Would you like a text reminder?",
          "Would you like a text reminder 24 hours before the appointment?",
          "Would you like a SMS reminder for this appointment?"
        ],
        reply <- ["Yes", "Yeah, that'd be helpful.", "Yes, that would be helpful!", "Yes, please"] do
      assert {:input, %{operation: "reminder_opt_in"}} =
               ReminderPolicy.interpret(snapshot(offer, reply), state, opts)
    end

    uncertain = [
      reminder_judge: fn _ -> {:error, :uncertain} end,
      phone_extractor: fn _ -> {:incomplete, [:phone]} end
    ]

    for offer <- [
          "Shall I book that?",
          "Would you not like a text reminder?",
          "Would you like marketing texts?",
          "Would you like a text reminder if you pay?",
          "Can we send the reminder to 0188?"
        ] do
      assert {:clarify, _} = ReminderPolicy.interpret(snapshot(offer, "Yes"), state, uncertain)
    end
  end

  test "a literal cell confirmation to an exact permission question needs no probabilistic judgment" do
    state = %{
      status: "verify_existing",
      destination: "+12025550188",
      patient: "p",
      original_phone: "2025550188"
    }

    opts = [reminder_judge: fn _ -> flunk("a literal verified answer needs no model") end]

    for question <- [
          "Great. I'll set that up now. Could we send it to your cell ending in zero one eight eight?",
          "Would you like a text reminder for this appointment? Can we send it to your cell number ending in zero one eight eight?",
          "Can we send the reminder to 0188?"
        ],
        answer <- ["Yep, that's my cell", "Yes, please", "Yep, that’s my cell."] do
      assert {:input, %{operation: "reminder_confirm", destination: "+12025550188"}} =
               ReminderPolicy.interpret(snapshot(question, answer), state, opts)
    end

    uncertain = [
      reminder_judge: fn _ -> {:error, :uncertain} end,
      phone_extractor: fn _ -> {:incomplete, [:phone]} end
    ]

    for question <- [
          "Can we send the reminder to 4289?",
          "Is 0188 your cell?",
          "Can we send marketing texts to 0188?",
          "Can we not send the reminder to 0188?",
          "The caller asked: Can we send the reminder to 0188?",
          "Can we send the reminder to 0188 if you pay?"
        ] do
      assert {:clarify, _} =
               ReminderPolicy.interpret(
                 snapshot(question, "Yep, that's my cell"),
                 state,
                 uncertain
               )
    end

    assert {:clarify, _} =
             ReminderPolicy.interpret(
               snapshot("Can we send the reminder to 0188?", "Yes, if it is free"),
               state,
               uncertain
             )
  end

  test "only the exact current destination readback can authorize scheduling" do
    state = %{
      status: "verify_existing",
      destination: "+12025550188",
      patient: "p",
      original_phone: "2025550188"
    }

    opts = [reminder_judge: fn _ -> {:ok, "confirm_number"} end]

    assert {:input, %{operation: "reminder_confirm", destination: "+12025550188"}} =
             ReminderPolicy.interpret(
               snapshot(
                 "Can we text your cell ending in zero one eight eight?",
                 "Yep, that's my cell."
               ),
               state,
               opts
             )

    assert {:clarify, _} =
             ReminderPolicy.interpret(
               snapshot("Can we text your cell ending in zero one eight nine?", "Yep."),
               state,
               opts
             )

    assert {:clarify, _} =
             ReminderPolicy.interpret(
               snapshot("Would you like a text reminder?", "Yep."),
               state,
               opts
             )

    new = %{state | status: "verify_new"}

    assert {:clarify, _} =
             ReminderPolicy.interpret(
               snapshot("Your cell ending in zero one eight eight?", "Yep."),
               new,
               opts
             )

    assert {:input, _} =
             ReminderPolicy.interpret(
               snapshot("Is two zero two five five five zero one eight eight correct?", "Yep."),
               new,
               opts
             )
  end

  test "booking yes cannot stand in for reminder consent" do
    state = %{status: "offered", patient: "p", original_phone: "2025550188"}
    opts = [reminder_judge: fn _ -> {:ok, "opt_in"} end]

    assert :associate =
             ReminderPolicy.interpret(snapshot("Shall I book Thursday?", "Yes."), state, opts)

    assert {:input, %{operation: "reminder_opt_in"}} =
             ReminderPolicy.interpret(
               snapshot("Would you like a text reminder?", "Yeah."),
               state,
               opts
             )
  end

  test "appointment changes and recovery controls can leave every unfinished reminder step" do
    for status <- ~w(offered need_number verify_existing verify_new) do
      state = %{
        status: status,
        patient: "p",
        original_phone: "2025550188",
        destination: "+12025550188"
      }

      assert :appointment =
               ReminderPolicy.interpret(
                 snapshot("Would you like a reminder?", "Cancel that appointment"),
                 state,
                 reminder_judge: fn _ -> {:ok, "appointment"} end,
                 phone_extractor: fn _ -> raise "not a phone answer" end
               )

      assert :appointment =
               ReminderPolicy.interpret(snapshot("Which number?", "Start over"), state,
                 reminder_judge: fn _ -> raise "literal recovery needs no model" end
               )
    end
  end

  test "structured phone extraction gets the caller binding and never authorizes scheduling" do
    state = %{status: "need_number", patient: "p", original_phone: nil}

    assert {:input, %{operation: "reminder_number", phone: "+12025550199"}} =
             ReminderPolicy.interpret(snapshot("What's your cell?", "2025550199"), state,
               reminder_judge: fn _ -> {:ok, "number"} end,
               phone_extractor: fn request ->
                 assert request.interpretation_binding.caller_cursor == 2
                 {:ok, %{phone: "+12025550199"}}
               end
             )
  end

  test "uncertainty preserves the reminder step and asks about the pending destination" do
    current = %{
      status: "verify_new",
      destination: "+12025550199",
      patient: "p",
      original_phone: nil
    }

    assert {:clarify, question} =
             ReminderPolicy.interpret(snapshot("Is this your new number?", "Maybe"), current,
               reminder_judge: fn _ -> {:error, :uncertain} end,
               phone_extractor: fn _ -> {:incomplete, [:phone]} end
             )

    assert question =~ BookingDesk.Reminders.spoken(current.destination)
    refute question =~ "Would you like a text reminder?"
  end

  test "a number supplied under uncertainty survives later turns but cannot authorize consent" do
    memory = start_supervised!(BookingDesk.Conversation)
    opts = [conversation: memory]
    s = struct(Parlora.ContextSnapshot, snapshot("What cell number?", "2025550199"))
    s = %{s | revision: 2}
    s = BookingDesk.Conversation.attach(s, opts)
    current = %{status: "need_number", destination: nil, patient: "p", original_phone: nil}

    assert {:clarify, _} =
             ReminderPolicy.interpret(
               s,
               current,
               opts ++
                 [
                   reminder_judge: fn _ -> {:error, :uncertain} end,
                   phone_extractor: fn _ -> {:ok, %{phone: "+12025550199"}} end
                 ]
             )

    later = %{
      s
      | revision: 30,
        transcripts: [%{speaker: :user, delta: "Use that number", arrival_order: 30}]
    }

    later = BookingDesk.Conversation.attach(later, opts)

    assert {:input, %{operation: "reminder_number", phone: "+12025550199"}} =
             ReminderPolicy.interpret(
               later,
               current,
               opts ++
                 [
                   reminder_judge: fn state ->
                     assert state.conversation.phone == "+12025550199"
                     {:ok, "number"}
                   end,
                   phone_extractor: fn _ -> {:incomplete, [:phone]} end
                 ]
             )

    old_question =
      struct(
        Parlora.ContextSnapshot,
        snapshot("Can we text your cell ending in zero one eight eight?", "Yes")
      )

    old_question = BookingDesk.Conversation.attach(%{old_question | revision: 31}, opts)
    old = %{current | status: "verify_existing", destination: "+12025550188"}

    assert {:clarify, _} =
             ReminderPolicy.interpret(
               old_question,
               old,
               opts ++ [reminder_judge: fn _ -> {:ok, "confirm_number"} end]
             )

    for status <- ["scheduled", "declined"] do
      assert :associate =
               ReminderPolicy.interpret(later, %{current | status: status},
                 reminder_judge: fn _ -> flunk("terminal reminder was reinterpreted") end
               )
    end

    offered = %{current | status: "offered"}

    assert {:clarify, question} =
             ReminderPolicy.interpret(
               later,
               offered,
               opts ++
                 [
                   reminder_judge: fn _ -> {:error, :uncertain} end,
                   phone_extractor: fn _ -> {:incomplete, [:phone]} end
                 ]
             )

    assert BookingDesk.Run.reminder_offer?(question)
  end

  test "conditional replies cannot grant reminder consent even with a confident classification" do
    offer = %{status: "offered", destination: nil, patient: "p", original_phone: nil}
    destination = %{offer | status: "verify_new", destination: "+12025550199"}

    for text <- [
          "Yes, if it is free",
          "Maybe",
          "No, don't send it",
          "Yes, but wait",
          "Yes, don’t send it"
        ] do
      assert :associate =
               ReminderPolicy.interpret(snapshot("Would you like a text reminder?", text), offer,
                 reminder_judge: fn _ -> {:ok, "opt_in"} end
               )

      assert {:clarify, _} =
               ReminderPolicy.interpret(
                 snapshot("Can we text two zero two five five five zero one nine nine?", text),
                 destination,
                 reminder_judge: fn _ -> {:ok, "confirm_number"} end
               )
    end
  end

  test "rechecking one phone fragment cannot feed that same fragment back as earlier evidence" do
    memory = start_supervised!(BookingDesk.Conversation)
    opts = [conversation: memory, reminder_judge: fn _ -> {:error, :uncertain} end]
    s = struct(Parlora.ContextSnapshot, snapshot("What cell number?", "202555"))
    current = %{status: "need_number", destination: nil, patient: "p", original_phone: nil}
    owner = self()

    extract = fn state ->
      send(owner, {:retained_digits, state.retained_phone_evidence})
      {:incomplete, [:phone], %{evidence: ["202555"]}}
    end

    for revision <- [2, 3] do
      turn = BookingDesk.Conversation.attach(%{s | revision: revision}, opts)

      assert {:clarify, _} =
               ReminderPolicy.interpret(turn, current, opts ++ [phone_extractor: extract])

      assert_receive {:retained_digits, []}
    end

    later = %{s | revision: 4, transcripts: [%{speaker: :user, delta: "0199", arrival_order: 3}]}
    later = BookingDesk.Conversation.attach(later, opts)

    assert {:clarify, _} =
             ReminderPolicy.interpret(
               later,
               current,
               opts ++
                 [
                   phone_extractor: fn state ->
                     assert state.retained_phone_evidence == ["202555"]

                     BookingDesk.Phone.validate(
                       %{"phone" => "+12025550199", "evidence" => ["202555", "0199"]},
                       state.latest_user,
                       state.retained_phone_evidence
                     )
                   end
                 ]
             )

    assert BookingDesk.Conversation.context(BookingDesk.Conversation.attach(later, opts)).phone ==
             "+12025550199"
  end

  test "streaming captions replace their own phone prefix instead of counting it twice" do
    memory = start_supervised!(BookingDesk.Conversation)

    opts = [
      conversation: memory,
      reminder_judge: fn _ -> {:error, :uncertain} end,
      phone_extractor: fn state ->
        assert state.retained_phone_evidence == []
        phone = if state.latest_user == "2025550199", do: "+12025550199"

        BookingDesk.Phone.validate(
          %{"phone" => phone, "evidence" => state.latest_user},
          state.latest_user
        )
      end
    ]

    current = %{status: "need_number", destination: nil, patient: "p", original_phone: nil}
    first = struct(Parlora.ContextSnapshot, snapshot("What cell number?", "202555"))
    first = %{first | revision: 2}

    assert {:clarify, _} =
             ReminderPolicy.interpret(BookingDesk.Conversation.attach(first, opts), current, opts)

    extended = %{
      first
      | revision: 3,
        transcripts: [%{speaker: :user, delta: "0", arrival_order: 3} | first.transcripts]
    }

    assert {:clarify, _} =
             ReminderPolicy.interpret(
               BookingDesk.Conversation.attach(extended, opts),
               current,
               opts
             )

    assert BookingDesk.Conversation.context(BookingDesk.Conversation.attach(extended, opts)).phone_evidence ==
             ["2025550"]

    complete = %{
      extended
      | revision: 4,
        transcripts: [%{speaker: :user, delta: "199", arrival_order: 4} | extended.transcripts]
    }

    for revision <- [4, 5] do
      turn = BookingDesk.Conversation.attach(%{complete | revision: revision}, opts)
      assert {:clarify, _} = ReminderPolicy.interpret(turn, current, opts)
    end

    assert BookingDesk.Conversation.context(
             BookingDesk.Conversation.attach(%{complete | revision: 5}, opts)
           ).phone == "+12025550199"
  end
end
