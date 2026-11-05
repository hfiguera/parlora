defmodule BookingDesk.PolicyTest do
  use ExUnit.Case, async: false
  alias Parlora.{ContextSnapshot, ContextTrigger}
  alias Parlora.Session.{DecisionValidation, State}

  defp snapshot(operation \\ "availability") do
    %ContextSnapshot{
      session_id: "test",
      provider_generation: 0,
      application_context: identity_context("test"),
      transcripts: [%{speaker: :user, delta: "Thursday instead", arrival_order: 8}],
      pending_delegations: %{"d" => %{status: :pending, received_at_us: 1}},
      tasks: %{
        "t" => %{
          id: "t",
          revision: 1,
          status: :submitted,
          input: %{operation: operation, date: "2026-11-04", clinician: "lee", cursor: 2}
        }
      }
    }
  end

  defp identity_context(session, patient \\ "p_1002") do
    {name, dob} =
      if patient == "p_1003",
        do: {"Alex Morgan", "1985-07-24"},
        else: {"Jamie Rivera", "1990-03-12"}

    request = "identity-" <> session <> patient

    BookingDesk.Store.execute(
      %{operation: "lookup", name: name, dob: dob, session: session},
      request
    )

    insurance = BookingDesk.Store.insurance(request, session)
    review = request <> "-insurance"

    BookingDesk.Store.execute(
      %{
        operation: "insurance",
        patient: patient,
        lookup_request: request,
        session: session,
        response: "unchanged",
        carrier: insurance.carrier,
        insurance_revision: insurance.revision
      },
      review
    )

    %{patient: patient, lookup_request: request, insurance_request: review}
  end

  defp execute(input, id) do
    context = identity_context("test", Map.get(input, :patient, "p_1002"))

    BookingDesk.Store.execute(
      Map.merge(
        %{
          session: "test",
          lookup_request: context.lookup_request,
          clinician: "lee",
          insurance_request: context.insurance_request
        },
        input
      ),
      id
    )
  end

  defp interpret(s, result, extraction \\ {:incomplete, [:name, :dob]}),
    do:
      BookingDesk.Policy.interpret(s, %ContextTrigger{kind: :delegation},
        coalesce_ms: 0,
        settle_confirm_ms: 0,
        judge: fn _ -> result end,
        identity_extractor: fn _ -> extraction end
      )

  test "invalid demographic evidence asks the caller to repeat it instead of claiming a service failure" do
    s = %ContextSnapshot{
      session_id: "microphone-diagnostic",
      provider_generation: 0,
      application_context: %{},
      transcripts: [
        %{speaker: :user, delta: "Jamie Rivera, March twenth, twenty twenty", arrival_order: 2},
        %{speaker: :assistant, delta: "Your full name and date of birth?", arrival_order: 1}
      ],
      tasks: %{},
      pending_delegations: %{"d" => %{status: :pending, received_at_us: 1}}
    }

    assert {:ok, [decision]} =
             interpret(s, {:ok, %{"intent" => "lookup"}}, {:error, :invalid_extraction})

    assert decision.kind == :request_clarification
    assert decision.message =~ "full name"
    assert decision.message =~ "birth month, day, and year"
    refute decision.message =~ "try again in a moment"
  end

  test "a new unclear caller reply can repeat a clarification for the same task" do
    s = snapshot()
    pending = {"d", s.pending_delegations["d"]}

    decide = fn cursor ->
      {:ok, [decision]} =
        BookingDesk.Policy.decide(
          s,
          {:error, :uncertain},
          pending,
          s.tasks["t"],
          cursor,
          "Ten fitting"
        )

      decision
    end

    first = decide.(8)
    same_reply = decide.(8)
    next_reply = decide.(9)
    assert first.kind == :request_clarification
    assert first.message == next_reply.message
    assert first.clarification_key == same_reply.clarification_key
    refute first.clarification_key == next_reply.clarification_key
    refute next_reply.kind == :start_task
  end

  test "a correction supersedes pending work, while an additional date starts separate work" do
    for {intent, kind} <- [
          {"replace_search", :supersede_task},
          {"additional_search", :start_task}
        ] do
      assert {:ok, [decision]} =
               interpret(snapshot(), {:ok, %{"intent" => intent, "date" => "2026-11-05"}})

      assert decision.kind == kind
      assert decision.input.date == "2026-11-05"
    end
  end

  test "progress questions associate existing work instead of repeating it" do
    assert {:ok, [decision]} = interpret(snapshot(), {:ok, %{"intent" => "progress"}})
    assert decision.kind == :associate_delegation
    assert decision.task_id == "t"
  end

  test "explicit retry refreshes a failed read and a fresh completed search can be checked again" do
    for status <- [:failed, :completed] do
      s = put_in(snapshot().tasks["t"][:status], status)
      s = %{s | transcripts: [%{speaker: :user, delta: "Please try again", arrival_order: 8}]}

      result =
        if status == :failed,
          do: {:ok, %{"intent" => "retry"}},
          else: {:ok, %{"intent" => "availability", "date" => "2026-11-04", "clinician" => "lee"}}

      assert {:ok, [decision]} = interpret(s, result)
      assert decision.kind == :supersede_task
      assert decision.input.operation == "availability"
    end
  end

  test "appointment changes requested before registration ask for identity rather than failing backend work" do
    for intent <- ~w(cancel choose_slot reschedule) do
      s = %ContextSnapshot{
        session_id: "unregistered",
        transcripts: [
          %{speaker: :user, delta: "Please help with my appointment", arrival_order: 8}
        ],
        pending_delegations: %{"d" => %{status: :pending, received_at_us: 1}}
      }

      assert {:ok, [decision]} =
               interpret(
                 s,
                 {:ok,
                  %{
                    "intent" => intent,
                    "date" => "2026-11-05",
                    "time" => "10:15",
                    "clinician" => "lee"
                  }}
               )

      assert decision.kind == :request_clarification
      assert decision.message =~ "full name"
    end
  end

  test "an unresolved reschedule date asks for that date before searching or proposing" do
    s = snapshot()
    s = put_in(s.tasks["t"][:context_wait], %{expired?: true, recheck_key: "uncertain:8"})

    assert {:ok, [question]} =
             interpret(
               s,
               {:incomplete,
                %{
                  "intent" => "reschedule",
                  "date" => "unknown",
                  "time" => "unknown",
                  "clinician" => "lee"
                }, ["date", "time"]}
             )

    assert question.kind == :request_clarification
    assert question.message =~ "What date"
  end

  test "a cancellation request survives registration and resumes as a proposal, not an availability search" do
    session = "cancel-registration"
    lookup = "cancel-registration-lookup"
    memory = start_supervised!(BookingDesk.Conversation)

    opts = [
      conversation: memory,
      coalesce_ms: 0,
      judge: fn _ -> raise "consumed registration must resume the stored goal" end
    ]

    initial = %ContextSnapshot{
      session_id: session,
      transcripts: [%{speaker: :user, delta: "Cancel my appointment", arrival_order: 1}]
    }

    current = BookingDesk.Conversation.attach(initial, opts)
    BookingDesk.Conversation.remember(current, opts, judgment: {:ok, %{"intent" => "cancel"}})

    BookingDesk.Store.execute(
      %{operation: "lookup", name: "Jamie Rivera", dob: "1990-03-12", session: session},
      lookup
    )

    s = %{
      initial
      | revision: 2,
        transcripts: [
          %{speaker: :user, delta: "Jamie Rivera, March twelfth, 1990", arrival_order: 8}
        ],
        tasks: %{
          "t" => %{
            id: "t",
            revision: 1,
            status: :completed,
            request_ids: [lookup],
            input: %{operation: "lookup", cursor: 8, name: "jamie rivera", dob: "1990-03-12"}
          }
        }
    }

    assert {:ok, [decision]} =
             BookingDesk.Policy.interpret(s, %ContextTrigger{kind: :backend_completed}, opts)

    assert decision.kind == :start_task
    assert decision.anchor_task_id == "t"
    assert decision.input.operation == "propose"
    assert decision.input.change == "cancel"

    assert :ok ==
             DecisionValidation.validate(%State{context: s, limits: %Parlora.Limits{}}, [decision])
  end

  test "start over clears unconfirmed data and a fresh patient cannot inherit old search preferences" do
    memory = start_supervised!(BookingDesk.Conversation)

    opts = [
      conversation: memory,
      coalesce_ms: 0,
      judge: fn _ -> raise "literal restart needs no model" end
    ]

    s = snapshot()
    initial = BookingDesk.Conversation.attach(s, opts)

    BookingDesk.Conversation.remember(initial, opts,
      judgment: {:ok, %{"intent" => "availability", "date" => "2026-11-05", "clinician" => "lee"}}
    )

    s = %{s | transcripts: [%{speaker: :user, delta: "Start over", arrival_order: 8}]}

    assert {:ok, [question]} =
             BookingDesk.Policy.interpret(s, %ContextTrigger{kind: :delegation}, opts)

    assert question.message =~ "full name"
    current = BookingDesk.Conversation.attach(s, opts)
    assert BookingDesk.Conversation.context(current).preferences == %{}
    assert BookingDesk.Policy.identity(current) == nil

    s = %{
      s
      | revision: s.revision + 1,
        transcripts: [%{speaker: :user, delta: "Alex Morgan, July 24, 1985", arrival_order: 20}]
    }

    assert {:ok, [lookup]} =
             BookingDesk.Policy.interpret(s, %ContextTrigger{kind: :delegation},
               conversation: memory,
               coalesce_ms: 0,
               judge: fn _ -> {:ok, %{"intent" => "lookup"}} end,
               identity_extractor: fn _ -> {:ok, %{name: "alex morgan", dob: "1985-07-24"}} end
             )

    assert lookup.input.operation == "lookup"
    assert lookup.input.date == nil
    assert lookup.input.clinician == nil
  end

  test "restart and retry while a booking is pending never repeat or hide the write" do
    for text <- ["Start over", "Please try again", "Cancel it", "Another date"] do
      s = %{snapshot("confirm") | transcripts: [%{speaker: :user, delta: text, arrival_order: 8}]}

      assert {:ok, [decision]} =
               BookingDesk.Policy.interpret(s, %ContextTrigger{kind: :delegation},
                 coalesce_ms: 0,
                 judge: fn _ -> raise "must await the admitted write" end
               )

      assert decision.kind == :associate_delegation
    end
  end

  test "a refused search correction is cleared so progress does not revive it" do
    s = snapshot()

    assert {:ok, [question]} =
             BookingDesk.Policy.decide(
               s,
               {:incomplete, %{"date" => "2026-11-05", "clinician" => "lee"}, ["intent"]},
               {"d", s.pending_delegations["d"]},
               s.tasks["t"],
               8,
               "Thursday?"
             )

    s = put_in(s.tasks["t"][:clarification], %{message: question.message, input: question.input})

    s = %{
      s
      | transcripts: [
          %{speaker: :user, delta: "No", arrival_order: 20},
          %{speaker: :assistant, delta: question.message, arrival_order: 10}
        ]
    }

    assert {:ok, [repeated]} =
             BookingDesk.Policy.decide(
               s,
               {:ok, %{"intent" => "repeat"}},
               {"d", s.pending_delegations["d"]},
               s.tasks["t"],
               20,
               "Repeat that"
             )

    assert repeated.kind == :request_clarification
    assert repeated.input.search_clarification == question.input.search_clarification

    assert {:ok, [declined]} =
             BookingDesk.Policy.decide(
               s,
               {:error, :uncertain},
               {"d", s.pending_delegations["d"]},
               s.tasks["t"],
               20,
               "No"
             )

    assert declined.input.unresolved_intent == false
    assert declined.input.booking_request["date"] == "2026-11-04"
    s = put_in(s.tasks["t"].clarification.input, declined.input)

    assert {:ok, [progress]} =
             BookingDesk.Policy.decide(
               s,
               {:ok, %{"intent" => "progress"}},
               {"d", s.pending_delegations["d"]},
               s.tasks["t"],
               21,
               "Still checking?"
             )

    assert progress.kind == :associate_delegation
  end

  test "refusing a proposal preserves the appointment and a later model yes cannot revive it" do
    s = snapshot("propose")

    execute(
      %{operation: "availability", patient: "p_1002", date: "2026-11-05", cursor: 777},
      "decline-offers"
    )

    execute(
      %{
        operation: "propose",
        patient: "p_1002",
        slot: "2026-11-05T10:15:00",
        revision: 778,
        search_cursor: 777
      },
      "decline-proposal"
    )

    input = %{
      operation: "propose",
      change: "book",
      slot: "2026-11-05T10:15:00",
      revision: 778,
      cursor: 778,
      patient: "p_1002",
      lookup_request: s.application_context.lookup_request
    }

    task =
      Map.merge(s.tasks["t"], %{
        status: :completed,
        input: input,
        request_ids: ["decline-proposal"]
      })

    s = %{
      s
      | tasks: %{"t" => task},
        transcripts: [
          %{speaker: :user, delta: "No", arrival_order: 800},
          %{
            speaker: :assistant,
            delta: "November fifth at 10:15 AM with Dr. Lee, shall I book it?",
            arrival_order: 790
          }
        ]
    }

    memory = start_supervised!(BookingDesk.Conversation)

    opts = [
      conversation: memory,
      coalesce_ms: 0,
      settle_confirm_ms: 0,
      judge: fn _ -> raise "plain refusal needs no model" end
    ]

    before = BookingDesk.Store.snapshot()

    assert {:ok, [declined]} =
             BookingDesk.Policy.interpret(s, %ContextTrigger{kind: :delegation}, opts)

    assert declined.kind == :request_clarification
    assert declined.message =~ "haven't accepted"
    current = BookingDesk.Conversation.attach(s, opts)
    assert BookingDesk.Policy.current_proposal(current) == nil
    s = %{s | transcripts: [%{speaker: :user, delta: "Yes", arrival_order: 810}]}

    opts =
      Keyword.put(opts, :judge, fn _ ->
        {:ok,
         %{"intent" => "confirm", "date" => "2026-11-05", "time" => "10:15", "clinician" => "lee"}}
      end)

    assert {:ok, [blocked]} =
             BookingDesk.Policy.interpret(s, %ContextTrigger{kind: :delegation}, opts)

    assert blocked.kind == :request_clarification
    assert BookingDesk.Store.snapshot() == before
  end

  test "a fresh availability request replaces a different search unless explicitly additional" do
    assert {:ok, [decision]} =
             interpret(snapshot(), {:ok, %{"intent" => "availability", "date" => "2026-11-05"}})

    assert decision.kind == :supersede_task
    assert decision.input.date == "2026-11-05"
  end

  test "explicitly returning to the old date settles its unresolved search question" do
    s = snapshot()

    s =
      put_in(s.tasks["t"][:clarification], %{
        input: %{
          unresolved_intent: true,
          booking_request: %{"date" => "2026-11-05"},
          lookup_request: s.application_context.lookup_request
        }
      })

    assert {:ok, [decision]} =
             interpret(s, {:ok, %{"intent" => "availability", "date" => "2026-11-04"}})

    assert decision.kind == :supersede_task
    assert decision.input.date == "2026-11-04"
  end

  test "preference recaps and service failures pass Parlora's decision validation" do
    s = snapshot()

    for result <- [
          {:incomplete, %{"date" => "2026-11-05", "clinician" => "lee"}, ["intent"]},
          {:error, :unavailable}
        ] do
      assert {:ok, [decision]} =
               BookingDesk.Policy.decide(
                 s,
                 result,
                 {"d", s.pending_delegations["d"]},
                 s.tasks["t"],
                 8,
                 "Thursday instead"
               )

      assert decision.kind == :request_clarification
      state = %State{context: s, limits: %Parlora.Limits{}}
      assert :ok == DecisionValidation.validate(state, [decision])
    end
  end

  test "progress cannot release an old search while a changed request awaits clarification" do
    s = snapshot()
    pending = {"d", s.pending_delegations["d"]}

    assert {:ok, [question]} =
             BookingDesk.Policy.decide(
               s,
               {:incomplete, %{"date" => "2026-11-05", "clinician" => "lee"}, ["intent"]},
               pending,
               s.tasks["t"],
               8,
               "What about November fifth?"
             )

    s = put_in(s.tasks["t"][:clarification], %{input: question.input})

    for intent <- ["progress", "none"] do
      assert {:ok, [decision]} =
               BookingDesk.Policy.decide(
                 s,
                 {:ok, %{"intent" => intent}},
                 pending,
                 s.tasks["t"],
                 9,
                 "Are you still checking?"
               )

      assert decision.kind == :request_clarification
      assert decision.message =~ "November 5"
      assert decision.input.booking_request["date"] == "2026-11-05"

      assert :ok ==
               DecisionValidation.validate(
                 %State{context: s, limits: %Parlora.Limits{}},
                 [decision]
               )
    end
  end

  test "a new caller question excludes identity words already consumed by backend work" do
    s = snapshot()

    task = %{
      s.tasks["t"]
      | input: %{operation: "availability", date: "2026-11-04", clinician: "lee", cursor: 9}
    }

    s = %{
      s
      | tasks: %{"t" => task},
        transcripts: [
          %{
            speaker: :user,
            delta: "While you're checking, what should I bring?",
            arrival_order: 10
          },
          %{speaker: :user, delta: "Jamie Rivera, March 12th, 1990.", arrival_order: 9}
        ]
    }

    assert {:ok, [decision]} =
             BookingDesk.Policy.interpret(s, %ContextTrigger{kind: :transcript_updated},
               coalesce_ms: 0,
               identity_extractor: fn _ -> raise "must not re-extract identity" end,
               judge: fn state ->
                 assert state.latest_user == "While you're checking, what should I bring?"
                 assert Enum.at(state.dialogue, -2).text == "Jamie Rivera, March 12th, 1990."
                 {:ok, %{"intent" => "none"}}
               end
             )

    assert decision.kind == :associate_delegation
  end

  test "overlapping assistant captions do not split the caller's preparation question" do
    # Actual GPT Live-1 speech timestamps: 'Please' arrives before the caller's
    # final word. Arrival order is not a caller turn boundary in duplex speech.
    parts = [
      {:user, "While you're checking, what should I bring to the", 23_000, 25_200},
      {:assistant, " Please", 25_400, 25_600},
      {:user, " appointment", 25_600, 25_800},
      {:assistant, " bring a photo ID and your insurance card.", 25_600, 27_600}
    ]

    transcripts =
      parts
      |> Enum.with_index(10)
      |> Enum.map(fn {{speaker, delta, first, last}, order} ->
        %{
          speaker: speaker,
          delta: delta,
          start_ms: first,
          end_ms: last,
          provider_generation: 0,
          arrival_order: order
        }
      end)
      |> Enum.reverse()

    s = %{snapshot() | transcripts: transcripts, provider_speech: :idle}
    s = put_in(s.tasks["t"][:context_wait], %{expired?: true, recheck_key: "uncertain:12"})

    assert {:ok, [decision]} =
             BookingDesk.Policy.interpret(s, %ContextTrigger{kind: :context_wait_expired},
               coalesce_ms: 0,
               judge: fn state ->
                 assert state.latest_user ==
                          "While you're checking, what should I bring to the appointment"

                 assert List.last(state.dialogue).text == state.latest_user
                 {:ok, %{"intent" => "none"}}
               end
             )

    assert decision.kind == :associate_delegation
  end

  test "uncertain fragments wait for more caller context before requesting clarification" do
    assert {:ok, [decision]} = interpret(snapshot(), {:error, :uncertain})
    assert decision.kind == :wait_for_context
    s = snapshot()

    task =
      Map.put(s.tasks["t"], :context_wait, %{expired?: true, recheck_key: decision.recheck_key})

    assert {:ok, [clarification]} = interpret(%{s | tasks: %{"t" => task}}, {:error, :uncertain})
    assert clarification.kind == :request_clarification
  end

  test "an uncertain date change retains all preferences and a short reply can resume the search" do
    s = snapshot()
    s = put_in(s.tasks["t"][:context_wait], %{expired?: true, recheck_key: "uncertain:8"})

    s = %{
      s
      | transcripts: [
          %{speaker: :user, delta: "November fifth at ten fifteen with Dr. Lee", arrival_order: 8}
        ]
    }

    result =
      uncertain_preferences(%{"date" => "2026-11-05", "clinician" => "lee", "time" => "10:15"})

    assert {:ok, [question]} = interpret(s, result)
    assert question.kind == :request_clarification

    assert question.input.booking_request == %{
             "date" => "2026-11-05",
             "clinician" => "lee",
             "time" => "10:15"
           }

    assert question.message =~ "November 5"
    assert question.message =~ "Dr. Lee"
    assert question.message =~ "10:15 AM"
    assert question.message =~ "Nothing has been booked"
    refute Map.has_key?(question.input.booking_request, "intent")

    s = put_in(s.tasks["t"][:clarification], %{input: question.input})

    s = %{
      s
      | transcripts: [%{speaker: :user, delta: "Check that date, please", arrival_order: 20}]
    }

    assert {:ok, [search]} =
             BookingDesk.Policy.interpret(s, %ContextTrigger{kind: :delegation},
               coalesce_ms: 0,
               judge: fn state ->
                 assert state.pending_request == question.input.booking_request
                 {:ok, Map.put(state.pending_request, "intent", "replace_search")}
               end
             )

    assert search.kind == :supersede_task
    assert search.input.operation == "availability"
    assert search.input.date == "2026-11-05"
    assert search.input.clinician == "lee"
  end

  test "successive uncertain replies merge validated preferences and remain bound to the patient" do
    s = snapshot()

    stored = %{
      booking_request: %{
        "intent" => "choose_slot",
        "date" => "2026-11-05",
        "clinician" => "lee",
        "time" => "10:15"
      },
      lookup_request: s.application_context.lookup_request
    }

    s = put_in(s.tasks["t"][:clarification], %{input: stored})
    s = put_in(s.tasks["t"][:context_wait], %{expired?: true, recheck_key: "uncertain:8"})

    for result <- [uncertain_preferences(%{"clinician" => "patel"}), {:error, :uncertain}] do
      assert {:ok, [question]} = interpret(s, result)
      assert question.kind == :request_clarification
      assert question.input.booking_request["date"] == "2026-11-05"
      assert question.input.booking_request["time"] == "10:15"
      expected = if result == {:error, :uncertain}, do: "lee", else: "patel"
      assert question.input.booking_request["clinician"] == expected
      refute Map.has_key?(question.input.booking_request, "intent")
      assert question.input.lookup_request == stored.lookup_request
    end

    s = put_in(s.tasks["t"].clarification.input.lookup_request, "another-patient")
    assert {:ok, [question]} = interpret(s, {:error, :uncertain})
    assert question.input.booking_request == %{}

    assert {:ok, [question]} =
             interpret(
               s,
               {:incomplete,
                %{"date" => "2099-01-01", "clinician" => "invented", "time" => "25:00"},
                ["intent"]}
             )

    assert question.input.booking_request == %{}
  end

  defp uncertain_preferences(fields, intent \\ "replace_search") do
    answers =
      Map.new(fields, fn {key, value} ->
        {key, %{choice: value, probabilities: %{value => 0.99}}}
      end)

    BookingDesk.Judgment.decode(
      Map.put(answers, "intent", %{choice: intent, probabilities: %{intent => 0.84}})
    )
  end

  test "a pending booking is not repeated when another confirmation arrives" do
    assert {:ok, [decision]} = interpret(snapshot("confirm"), {:ok, %{"intent" => "confirm"}})
    assert decision.kind == :associate_delegation
  end

  test "uncertain speech during an admitted write cannot hold its verified result" do
    assert {:ok, [decision]} = interpret(snapshot("confirm"), {:error, :uncertain})
    assert decision.kind == :associate_delegation

    assert {:ok, [partial]} =
             interpret(
               snapshot("confirm"),
               {:incomplete, %{"intent" => "confirm", "time" => "unknown"}, ["time"]}
             )

    assert partial.kind == :associate_delegation
  end

  test "a model confirmation without a current immutable proposal cannot book" do
    assert {:ok, [decision]} = interpret(snapshot(), {:ok, %{"intent" => "confirm"}})
    assert decision.kind == :request_clarification
  end

  test "low confidence dates cannot become scheduling commands" do
    answers = %{
      "intent" => %{choice: "availability", probabilities: %{"availability" => 0.99}},
      "date" => %{choice: "2026-11-05", probabilities: %{"2026-11-05" => 0.6}}
    }

    assert {:incomplete, %{"date" => "unknown"} = judgment, ["date"]} =
             BookingDesk.Judgment.decode(answers)

    s = snapshot()

    assert {:ok, [clarification]} =
             BookingDesk.Policy.decide(
               s,
               {:incomplete, judgment, ["date"]},
               {"d", s.pending_delegations["d"]},
               s.tasks["t"],
               8,
               "Thursday"
             )

    assert clarification.kind == :request_clarification
    refute Map.has_key?(clarification.input.booking_request, "date")
    borderline = put_in(answers, ["date", :probabilities, "2026-11-05"], 0.84)

    assert {:incomplete, %{"date" => "unknown"}, ["date"]} =
             BookingDesk.Judgment.decode(borderline)

    accepted = put_in(answers, ["date", :probabilities, "2026-11-05"], 0.85)
    assert {:ok, %{"date" => "2026-11-05"}} = BookingDesk.Judgment.decode(accepted)
  end

  test "a doctor-only reply asks for the missing date and survives the clarification handoff" do
    s = snapshot("insurance")
    s = put_in(s.tasks["t"].status, :completed)
    s = put_in(s.tasks["t"].input.date, "unknown")
    s = put_in(s.tasks["t"].input.clinician, nil)
    s = put_in(s.tasks["t"][:context_wait], %{expired?: true, recheck_key: "uncertain:8"})

    s = %{
      s
      | transcripts: [%{speaker: :user, delta: "Uh, what about Dr. Lee?", arrival_order: 8}]
    }

    partial =
      {:incomplete, %{"intent" => "availability", "date" => "unknown", "clinician" => "lee"},
       ["date"]}

    assert {:ok, [question]} = interpret(s, partial)
    assert question.kind == :request_clarification
    assert question.message == "What date would you like to see Dr. Lee?"
    assert question.input.booking_request == %{"intent" => "availability", "clinician" => "lee"}

    # Parlora preserves clarification input without changing the old task input.
    s = put_in(s.tasks["t"][:clarification], %{input: question.input})
    s = %{s | transcripts: [%{speaker: :user, delta: "November fifth", arrival_order: 20}]}

    assert {:ok, [decision]} =
             BookingDesk.Policy.interpret(s, %ContextTrigger{kind: :delegation},
               coalesce_ms: 0,
               judge: fn state ->
                 assert state.pending_request["clinician"] == "lee"
                 assert state.latest_user == "November fifth"

                 {:ok,
                  %{"intent" => "availability", "date" => "2026-11-05", "clinician" => "lee"}}
               end
             )

    assert decision.kind == :start_task
    assert decision.input.operation == "availability"
    assert decision.input.date == "2026-11-05"
    assert decision.input.clinician == "lee"

    # Preferences associated with another patient lookup cannot cross over.
    s = put_in(s.tasks["t"].clarification.input.lookup_request, "other-patient-lookup")

    assert {:ok, _} =
             BookingDesk.Policy.interpret(s, %ContextTrigger{kind: :delegation},
               coalesce_ms: 0,
               judge: fn state ->
                 assert state.pending_request == %{}
                 {:ok, %{"intent" => "none"}}
               end
             )
  end

  test "morning selection receives only current verified offers and proposes without booking" do
    s = snapshot()

    input =
      Map.merge(
        s.tasks["t"].input,
        Map.merge(
          s.application_context,
          %{operation: "availability", session: "test", cursor: 3, date: "2026-11-05"}
        )
      )

    execute(input, "microphone-morning-offers")
    s = put_in(s.tasks["t"], %{s.tasks["t"] | status: :completed, input: input})

    s = %{
      s
      | transcripts: [
          %{speaker: :user, delta: "The morning one, please.", arrival_order: 8},
          %{
            speaker: :assistant,
            delta: "Dr. Lee has 10:15 AM or 2 PM. Which would you prefer?",
            arrival_order: 7
          }
        ]
    }

    judge = fn state ->
      assert Enum.sort_by(state.verified_offers, & &1.time) == [
               %{date: "2026-11-05", time: "10:15", clinician: "lee"},
               %{date: "2026-11-05", time: "14:00", clinician: "lee"}
             ]

      assert state.latest_user == "The morning one, please."

      {:ok,
       %{
         "intent" => "choose_slot",
         "date" => "2026-11-05",
         "time" => "10:15",
         "clinician" => "lee"
       }}
    end

    assert {:ok, [proposal]} =
             BookingDesk.Policy.interpret(s, %ContextTrigger{kind: :delegation},
               coalesce_ms: 0,
               judge: judge
             )

    assert proposal.kind == :start_task
    assert proposal.input.operation == "propose"
    assert proposal.input.slot == "2026-11-05T10:15:00"
    assert length(BookingDesk.Store.snapshot()) == 1

    # A replacement still running cannot expose the old completed options.
    s =
      put_in(s.tasks["new"], %{
        id: "new",
        revision: 1,
        status: :submitted,
        input: %{input | cursor: 6, date: "2026-11-04"}
      })

    assert {:ok, _} =
             BookingDesk.Policy.interpret(s, %ContextTrigger{kind: :delegation},
               coalesce_ms: 0,
               judge: fn state ->
                 assert state.verified_offers == []
                 {:ok, %{"intent" => "none"}}
               end
             )
  end

  test "a model confirmation for a different slot cannot authorize the current proposal" do
    execute(
      %{operation: "availability", date: "2026-11-05", patient: "p_1002", cursor: 3},
      "policy-offer"
    )

    execute(
      %{
        operation: "propose",
        patient: "p_1002",
        slot: "2026-11-05T10:15:00",
        revision: 4,
        search_cursor: 3
      },
      "policy-proposal"
    )

    s = snapshot("propose")

    task =
      Map.merge(s.tasks["t"], %{
        status: :completed,
        input: %{
          operation: "propose",
          revision: 4,
          cursor: 2,
          patient: "p_1002",
          lookup_request: s.application_context.lookup_request,
          change: "book",
          slot: "2026-11-05T10:15:00"
        },
        request_ids: ["policy-proposal"]
      })

    s = %{
      s
      | tasks: %{"t" => task},
        transcripts: [%{speaker: :user, delta: "Yes, please book Wednesday", arrival_order: 8}]
    }

    assert {:ok, [decision]} =
             interpret(
               s,
               {:ok,
                %{
                  "intent" => "confirm",
                  "date" => "2026-11-04",
                  "time" => "10:15",
                  "clinician" => "lee"
                }}
             )

    assert decision.kind == :request_clarification
    assert length(BookingDesk.Store.snapshot()) == 1
  end

  test "short slot choices and approvals remain bound to verified state" do
    execute(
      %{operation: "availability", date: "2026-11-05", patient: "p_1002", cursor: 30},
      "context-offer"
    )

    s = snapshot()

    task = %{
      id: "t",
      revision: 1,
      status: :completed,
      input: %{operation: "availability", date: "2026-11-05", clinician: "lee", cursor: 30}
    }

    s = %{
      s
      | tasks: %{"t" => task},
        transcripts: [%{speaker: :user, delta: "Ten fifteen, please.", arrival_order: 31}]
    }

    assert {:ok, [choice]} =
             interpret(
               s,
               {:ok, %{"intent" => "choose_slot", "date" => "2026-11-05", "time" => "10:15"}}
             )

    assert choice.input.slot == "2026-11-05T10:15:00"
    execute(choice.input, "context-proposal")

    proposal = Map.merge(task, %{input: choice.input, request_ids: ["context-proposal"]})

    s = %{
      s
      | tasks: %{"t" => proposal},
        transcripts: [%{speaker: :user, delta: "Yes, please.", arrival_order: 32}]
    }

    preferences = %{"date" => "2026-11-05", "time" => "10:15", "clinician" => "lee"}
    uncertain = uncertain_preferences(preferences, "confirm")
    assert {:ok, [wait]} = interpret(s, uncertain)
    assert wait.kind == :wait_for_context

    held = put_in(s.tasks["t"][:context_wait], %{expired?: true, recheck_key: wait.recheck_key})
    assert {:ok, [question]} = interpret(held, uncertain)
    assert question.kind == :request_clarification
    assert question.input.booking_request == preferences

    remembered = put_in(held.tasks["t"][:clarification], %{input: question.input})

    for rejected <- [
          {:incomplete, Map.put(preferences, "intent", "confirm"), ["intent"]},
          {:incomplete, Map.merge(preferences, %{"intent" => "confirm", "time" => "unknown"}),
           ["time"]},
          {:ok, Map.merge(preferences, %{"intent" => "confirm", "date" => "2026-11-04"})},
          {:ok, Map.merge(preferences, %{"intent" => "confirm", "clinician" => "patel"})}
        ] do
      assert {:ok, [decision]} = interpret(remembered, rejected)
      assert decision.kind == :request_clarification
    end

    assert length(BookingDesk.Store.snapshot()) == 1

    judgment =
      {:ok,
       %{"intent" => "confirm", "date" => "2026-11-05", "time" => "10:15", "clinician" => "lee"}}

    for correction <- [
          %{"date" => "2026-11-04"},
          %{"time" => "14:00"},
          %{"clinician" => "patel"}
        ] do
      changed =
        put_in(
          remembered.tasks["t"].clarification.input.booking_request,
          Map.merge(preferences, correction)
        )

      assert {:ok, [rejected]} = interpret(changed, judgment)
      assert rejected.kind == :request_clarification
    end

    assert {:ok, [approval]} = interpret(remembered, judgment)
    assert approval.input.operation == "confirm"
    assert approval.input.proposal == "context-proposal"
    assert approval.input.revision == 31

    any_doctor =
      put_in(remembered.tasks["t"].clarification.input.booking_request["clinician"], "any")

    assert {:ok, [any_approval]} = interpret(any_doctor, judgment)
    assert any_approval.input == approval.input

    for clinician <- ["unknown", "patel", nil] do
      assert {:ok, [rejected]} =
               interpret(
                 s,
                 {:ok,
                  %{
                    "intent" => "confirm",
                    "date" => "2026-11-05",
                    "time" => "10:15",
                    "clinician" => clinician
                  }}
               )

      assert rejected.kind == :request_clarification
    end

    assert {:ok, [conversational]} =
             interpret(
               %{
                 s
                 | transcripts: [
                     %{
                       speaker: :user,
                       delta: "Yeah, go ahead and book it.",
                       arrival_order: 32
                     }
                   ]
               },
               judgment
             )

    assert conversational.input == approval.input

    partial = %{s | transcripts: [%{speaker: :user, delta: "Yeah", arrival_order: 32}]}
    assert {:ok, [wait]} = interpret(partial, judgment)
    assert wait.kind == :wait_for_context
    assert wait.recheck_after_ms == 1_500
    assert wait.recheck_key == "uncertain:32"

    full = %{
      partial
      | transcripts: [
          %{speaker: :user, delta: "Yeah, go ahead and book it.", arrival_order: 33}
        ]
    }

    assert {:ok, [completed]} = interpret(full, judgment)
    assert completed.input == Map.put(approval.input, :cursor, 33)

    expired_partial = %{
      partial
      | tasks: %{
          "t" =>
            Map.put(partial.tasks["t"], :context_wait, %{
              expired?: true,
              recheck_key: wait.recheck_key
            })
        }
    }

    assert {:ok, [incomplete]} = interpret(expired_partial, judgment)
    assert incomplete.kind == :request_clarification

    conditional_task =
      Map.put(proposal, :context_wait, %{expired?: true, recheck_key: "uncertain:32"})

    assert {:ok, [conditional]} =
             interpret(
               %{
                 s
                 | tasks: %{"t" => conditional_task},
                   transcripts: [
                     %{speaker: :user, delta: "Yes, if it's free.", arrival_order: 32}
                   ]
               },
               judgment
             )

    assert conditional.kind == :request_clarification
  end

  test "deferring an initial delegation during speech schedules a recheck and resumes when idle" do
    s = %{snapshot() | tasks: %{}, provider_speech: :speaking}

    s = %{
      s
      | transcripts: [
          %{speaker: :assistant, delta: "Checking that", arrival_order: 9} | s.transcripts
        ]
    }

    assert {:ok, [wait]} =
             BookingDesk.Policy.interpret(s, %ContextTrigger{kind: :transcript_updated},
               coalesce_ms: 0,
               judge: fn _ -> raise "must defer" end
             )

    assert wait.kind == :wait_for_context and wait.delegation_id == "d"
    assert wait.recheck_after_ms == 200

    assert {:ok, [start]} =
             BookingDesk.Policy.interpret(
               %{s | provider_speech: :idle},
               %ContextTrigger{kind: :context_wait_expired},
               coalesce_ms: 0,
               judge: fn _ ->
                 {:ok,
                  %{"intent" => "availability", "date" => "2026-11-04", "clinician" => "lee"}}
               end
             )

    assert start.kind == :start_task
  end

  test "a correction holds old results until the provider opens its new delegation" do
    s = %{snapshot() | pending_delegations: %{}}

    assert {:ok, [wait]} =
             interpret(s, {:ok, %{"intent" => "replace_search", "date" => "2026-11-05"}})

    assert wait.kind == :wait_for_context
    assert wait.task_id == "t"
  end

  test "native busy mode revises validated availability through its existing correlation only" do
    s = %{snapshot() | pending_delegations: %{}}
    task = Map.put(s.tasks["t"], :delegation_id, "original-call")
    s = %{s | tasks: %{"t" => task}}

    opts = [
      phonic_busy: true,
      coalesce_ms: 0,
      judge: fn _ ->
        {:ok, %{"intent" => "replace_search", "date" => "2026-11-05", "clinician" => "lee"}}
      end
    ]

    for status <- [:submitted, :completed] do
      current = put_in(s.tasks["t"].status, status)

      assert {:ok, [revision]} =
               BookingDesk.Policy.interpret(
                 current,
                 %ContextTrigger{kind: :transcript_updated},
                 opts
               )

      assert revision.kind == :supersede_task
      assert revision.task_id == "t" and revision.expected_task_revision == 1
      assert revision.delegation_id == nil
      assert revision.input.operation == "availability" and revision.input.date == "2026-11-05"
    end

    uncorrelated = put_in(s.tasks["t"].delegation_id, nil)

    assert {:ok, [wait]} =
             BookingDesk.Policy.interpret(
               uncorrelated,
               %ContextTrigger{kind: :transcript_updated},
               opts
             )

    assert wait.kind == :wait_for_context

    aliased = %{
      uncorrelated
      | pending_delegations: %{"alias" => %{status: :claimed, task_id: "t", task_revision: 1}}
    }

    assert {:ok, [revision]} =
             BookingDesk.Policy.interpret(
               aliased,
               %ContextTrigger{kind: :transcript_updated},
               opts
             )

    assert revision.kind == :supersede_task and revision.delegation_id == nil

    assert {:ok, [default]} =
             interpret(s, {:ok, %{"intent" => "replace_search", "date" => "2026-11-05"}})

    assert default.kind == :wait_for_context
  end

  test "native busy read recovery cannot replace fresh delegation or a verified proposal for writes" do
    s = %{snapshot() | pending_delegations: %{}}
    task = s.tasks["t"] |> Map.put(:delegation_id, "old-call") |> Map.put(:status, :completed)
    s = %{s | tasks: %{"t" => task}}
    before = BookingDesk.Store.snapshot()

    for intent <- ["choose_slot", "confirm"] do
      opts = [
        phonic_busy: true,
        coalesce_ms: 0,
        settle_confirm_ms: 0,
        judge: fn _ ->
          {:ok,
           %{"intent" => intent, "date" => "2026-11-04", "time" => "10:15", "clinician" => "lee"}}
        end
      ]

      assert {:ok, decisions} =
               BookingDesk.Policy.interpret(s, %ContextTrigger{kind: :transcript_updated}, opts)

      refute Enum.any?(decisions, &(&1.kind in [:start_task, :supersede_task]))
    end

    assert BookingDesk.Store.snapshot() == before
  end

  test "a validated slot survives assistant acknowledgments until delegation, but not new caller or booking context" do
    s = snapshot()

    task = %{
      s.tasks["t"]
      | status: :completed,
        input: %{operation: "availability", date: "2026-11-05", clinician: "lee", cursor: 30}
    }

    s = %{
      s
      | session_id: "slot-ack-regression",
        application_context: identity_context("slot-ack-regression"),
        tasks: %{"t" => task},
        pending_delegations: %{},
        transcripts: [%{speaker: :user, delta: "Ten fifteen, please.", arrival_order: 31}]
    }

    choice = {:ok, %{"intent" => "choose_slot", "date" => "2026-11-05", "time" => "10:15"}}

    BookingDesk.Store.execute(
      %{
        operation: "availability",
        date: "2026-11-05",
        clinician: "lee",
        cursor: 30,
        patient: "p_1002",
        session: s.session_id,
        lookup_request: s.application_context.lookup_request,
        insurance_request: s.application_context.insurance_request
      },
      "ack-regression-offer"
    )

    judge = fn state ->
      BookingDesk.Judgment.classify(state,
        evaluator: fn _ ->
          send(self(), :evaluated)
          choice
        end
      )
    end

    assert {:ok, [wait]} =
             BookingDesk.Policy.interpret(s, %ContextTrigger{kind: :transcript_updated},
               coalesce_ms: 0,
               judge: judge
             )

    assert wait.kind == :wait_for_context
    assert_received :evaluated

    ack = %{
      s
      | transcripts: [
          %{speaker: :assistant, delta: "Hmm. Okay. I'll check that time.", arrival_order: 32}
          | s.transcripts
        ],
        pending_delegations: %{"d" => %{status: :pending, received_at_us: 1}}
    }

    uncertain = fn state ->
      BookingDesk.Judgment.classify(state,
        evaluator: fn _ ->
          send(self(), :reevaluated)
          {:error, :uncertain}
        end
      )
    end

    assert {:ok, [proposal]} =
             BookingDesk.Policy.interpret(ack, %ContextTrigger{kind: :delegation},
               coalesce_ms: 0,
               judge: uncertain
             )

    assert proposal.kind == :start_task
    assert proposal.input.operation == "propose"
    assert proposal.input.slot == "2026-11-05T10:15:00"
    refute_received :reevaluated

    changed = [
      %{
        ack
        | transcripts: [
            %{speaker: :user, delta: "Actually, two PM instead.", arrival_order: 33}
            | ack.transcripts
          ]
      },
      %{ack | tasks: %{"t" => %{task | revision: 2}}},
      %{ack | tasks: %{"t" => %{task | status: :submitted}}},
      %{ack | application_context: %{patient: "different-patient"}},
      %{ack | provider_generation: 1},
      %{ack | session_id: "another-session"}
    ]

    for updated <- changed do
      assert {:ok, [decision]} =
               BookingDesk.Policy.interpret(updated, %ContextTrigger{kind: :delegation},
                 coalesce_ms: 0,
                 judge: uncertain
               )

      assert decision.kind == :wait_for_context
      assert_received :reevaluated
    end
  end

  test "an unavailable evaluator does not ask the caller to repeat an already complete request" do
    s = snapshot()
    assert {:ok, [wait]} = interpret(s, {:error, :unavailable})
    task = Map.put(s.tasks["t"], :context_wait, %{expired?: true, recheck_key: wait.recheck_key})
    assert {:ok, [decision]} = interpret(%{s | tasks: %{"t" => task}}, {:error, :unavailable})
    assert decision.kind == :request_clarification
    assert decision.message =~ "trouble checking"
    refute decision.message =~ "repeat"
  end

  test "an unselected patient must match demographics before an anchored availability search" do
    s = %{
      snapshot()
      | session_id: "demographic-flow",
        application_context: %{},
        tasks: %{},
        transcripts: [
          %{
            speaker: :user,
            delta: "Sure, it's Jamie Rivera. March twelfth, nineteen ninety.",
            arrival_order: 8
          }
        ]
    }

    result = {:ok, %{"intent" => "lookup", "date" => "2026-11-04", "clinician" => "lee"}}

    assert {:ok, [lookup]} =
             interpret(s, result, {:ok, %{name: "jamie rivera", dob: "1990-03-12"}})

    assert lookup.kind == :start_task
    assert lookup.input.name == "jamie rivera"
    assert lookup.input.dob == "1990-03-12"
    refute Map.has_key?(lookup.input, :patient)
    assert BookingDesk.Policy.patient(s) == nil
    BookingDesk.Store.execute(lookup.input, "demographic-lookup")

    task = %{
      id: "lookup-task",
      revision: 1,
      status: :completed,
      input: lookup.input,
      request_ids: ["demographic-lookup"]
    }

    matched = %{s | tasks: %{"lookup-task" => task}, pending_delegations: %{}}
    assert BookingDesk.Policy.patient(matched) == "p_1002"

    assert {:ok, []} =
             BookingDesk.Policy.interpret(matched, %ContextTrigger{kind: :backend_completed},
               coalesce_ms: 0,
               judge: fn _ -> raise "must release matched result without calendar work" end
             )

    refute BookingDesk.Policy.insurance(matched).confirmed

    answered = %{
      matched
      | pending_delegations: %{"d" => %{status: :pending, received_at_us: 1}},
        transcripts: [
          %{speaker: :user, delta: "Yep, that's still the same.", arrival_order: 9}
          | s.transcripts
        ]
    }

    assert {:ok, [wait]} = interpret(answered, {:ok, %{"intent" => "insurance_same"}})
    assert wait.kind == :wait_for_context

    answered =
      put_in(answered.tasks["lookup-task"][:context_wait], %{
        expired?: true,
        recheck_key: wait.recheck_key
      })

    assert {:ok, [review]} = interpret(answered, {:ok, %{"intent" => "insurance_same"}})
    assert review.input.operation == "insurance"
    assert review.input.response == "unchanged"
    assert review.input.carrier == "Aetna"
    assert review.input.date == "2026-11-04"
    BookingDesk.Store.execute(review.input, "demographic-insurance")

    reviewed = %{
      answered
      | pending_delegations: %{},
        tasks:
          Map.put(answered.tasks, "insurance-task", %{
            id: "insurance-task",
            revision: 1,
            status: :completed,
            input: review.input,
            request_ids: ["demographic-insurance"]
          })
    }

    assert {:ok, [availability]} =
             BookingDesk.Policy.interpret(reviewed, %ContextTrigger{kind: :backend_completed},
               coalesce_ms: 0,
               judge: fn _ -> raise "must resume reviewed request" end
             )

    assert availability.kind == :start_task
    assert availability.anchor_task_id == "insurance-task"
    assert availability.input.patient == "p_1002"
    assert availability.input.lookup_request == "demographic-lookup"
    assert availability.input.insurance_request == "demographic-insurance"
    assert availability.input.date == "2026-11-04"
    assert availability.input.clinician == "lee"

    assert {:ok, [question]} =
             interpret(
               %{
                 s
                 | transcripts: [%{speaker: :user, delta: "Check Wednesday", arrival_order: 9}]
               },
               {:ok, %{"intent" => "availability", "date" => "2026-11-04", "clinician" => "lee"}}
             )

    assert question.kind == :request_clarification
    assert question.message =~ "date of birth"
  end

  test "structured demographics gate lookup without delegating patient selection to the model" do
    s = %{
      snapshot()
      | tasks: %{},
        application_context: %{},
        transcripts: [
          %{
            speaker: :user,
            delta: "Yep, Jamie Rivera here. March twelfth, nineteen ninety.",
            arrival_order: 8
          },
          %{
            speaker: :assistant,
            delta: "Could I have your full name and date of birth?",
            arrival_order: 7
          }
        ]
    }

    result = {:ok, %{"intent" => "availability", "date" => "2026-11-04", "clinician" => "lee"}}

    output = %{
      "status" => "complete",
      "full_name" => "Jamie Rivera",
      "dob" => "1990-03-12",
      "name_evidence" => "Jamie Rivera",
      "dob_evidence" => ["March twelfth, nineteen ninety"]
    }

    assert {:ok, [lookup]} =
             BookingDesk.Policy.interpret(s, %ContextTrigger{kind: :delegation},
               coalesce_ms: 0,
               judge: fn _ -> result end,
               identity_extractor: fn state -> BookingDesk.Identity.validate(output, state) end
             )

    assert lookup.kind == :start_task
    assert lookup.input.operation == "lookup"
    assert lookup.input.name == "jamie rivera"
    refute Map.has_key?(lookup.input, :patient)

    for extraction <- [
          :pending,
          {:error, :unavailable},
          {:error, :invalid_extraction},
          {:incomplete, [:dob]}
        ] do
      assert {:ok, [decision]} = interpret(s, result, extraction)
      refute decision.kind == :start_task

      if extraction == :pending do
        assert String.starts_with?(decision.recheck_key, "identity:8:")

        expired =
          Map.put(s.pending_delegations["d"], :context_wait, %{
            expired?: true,
            recheck_key: decision.recheck_key
          })

        assert {:ok, [poll]} =
                 interpret(%{s | pending_delegations: %{"d" => expired}}, result, :pending)

        assert poll.kind == :wait_for_context
        refute poll.recheck_key == decision.recheck_key
      end

      case extraction do
        {:error, :invalid_extraction} -> assert decision.message =~ "couldn't verify"
        {:error, :unavailable} -> assert decision.message =~ "trouble reading"
        _ -> :ok
      end
    end

    pending =
      Map.put(s.pending_delegations["d"], :context_wait, %{
        expired?: true,
        recheck_key: "uncertain:8"
      })

    assert {:ok, [missing]} =
             interpret(
               %{s | pending_delegations: %{"d" => pending}},
               result,
               {:incomplete, [:dob]}
             )

    assert missing.message =~ "complete date of birth"
    refute missing.message =~ "full name"

    mismatch =
      BookingDesk.Store.execute(%{lookup.input | dob: "1991-03-12"}, "structured-wrong-dob")

    assert mismatch["status"] == "failed"
    assert BookingDesk.Store.identity("structured-wrong-dob", s.session_id) == nil
  end

  test "no doctor preference is supported, but a shared time cannot silently choose a doctor" do
    execute(
      %{
        operation: "availability",
        date: "2026-11-05",
        clinician: "any",
        cursor: 200,
        patient: "p_1002"
      },
      "multi-doctor-offer"
    )

    s = snapshot()

    task = %{
      s.tasks["t"]
      | status: :completed,
        input: %{operation: "availability", date: "2026-11-05", clinician: "any", cursor: 200}
    }

    s = %{
      s
      | tasks: %{"t" => task},
        transcripts: [%{speaker: :user, delta: "Ten fifteen, please.", arrival_order: 201}]
    }

    assert {:ok, [question]} =
             interpret(
               s,
               {:ok,
                %{
                  "intent" => "choose_slot",
                  "date" => "2026-11-05",
                  "time" => "10:15",
                  "clinician" => "any"
                }}
             )

    assert question.kind == :request_clarification
    assert question.message =~ "Which doctor"

    assert {:ok, [proposal]} =
             interpret(
               s,
               {:ok,
                %{
                  "intent" => "choose_slot",
                  "date" => "2026-11-05",
                  "time" => "10:15",
                  "clinician" => "patel"
                }}
             )

    assert proposal.input.clinician == "patel"
    assert proposal.input.slot == "2026-11-05T10:15:00@patel"
  end

  test "insurance replies wait for complete wording and grounded updates preserve appointment context" do
    session = "insurance-policy"

    BookingDesk.Store.execute(
      %{operation: "lookup", name: "Jamie Rivera", dob: "1990-03-12", session: session},
      "insurance-policy-lookup"
    )

    s = %{
      snapshot()
      | session_id: session,
        application_context: %{lookup_request: "insurance-policy-lookup"},
        transcripts: [%{speaker: :user, delta: "Yep", arrival_order: 9}],
        tasks: %{
          "t" => %{
            id: "t",
            revision: 1,
            status: :completed,
            request_ids: ["insurance-policy-lookup"],
            input: %{operation: "lookup", date: "2026-11-04", clinician: "lee", cursor: 8}
          }
        }
    }

    assert {:ok, [wait]} = interpret(s, {:ok, %{"intent" => "insurance_same"}})
    assert wait.kind == :wait_for_context

    changed = %{
      s
      | transcripts: [%{speaker: :user, delta: "Actually, that changed.", arrival_order: 10}]
    }

    assert {:ok, [new_wait]} = interpret(changed, {:ok, %{"intent" => "insurance_changed"}})
    refute wait.recheck_key == new_wait.recheck_key

    changed =
      put_in(changed.tasks["t"][:context_wait], %{
        expired?: true,
        recheck_key: new_wait.recheck_key
      })

    assert {:ok, [change]} = interpret(changed, {:ok, %{"intent" => "insurance_changed"}})
    assert change.input.response == "changed"
    assert change.input.date == "2026-11-04"
    refute Map.has_key?(change.input, :proposal)

    updated = %{
      s
      | transcripts: [%{speaker: :user, delta: "I switched to Cigna.", arrival_order: 11}]
    }

    for extraction <- [
          {:ok, %{carrier: "Cigna"}},
          :pending,
          {:incomplete, [:carrier]},
          {:error, :unavailable}
        ] do
      assert {:ok, [decision]} =
               BookingDesk.Policy.interpret(updated, %ContextTrigger{kind: :delegation},
                 coalesce_ms: 0,
                 judge: fn _ -> {:ok, %{"intent" => "insurance_update"}} end,
                 insurance_extractor: fn state ->
                   assert state.latest_user == "I switched to Cigna."
                   extraction
                 end
               )

      if match?({:ok, _}, extraction) do
        assert decision.input.operation == "insurance"
        assert decision.input.response == "updated"
        assert decision.input.carrier == "Cigna"
        assert decision.input.date == "2026-11-04"
        assert decision.input.clinician == "lee"
      else
        refute decision.kind == :start_task
      end
    end

    assert {:ok, [blocked]} =
             interpret(
               s,
               {:ok, %{"intent" => "availability", "date" => "2026-11-04", "clinician" => "lee"}}
             )

    assert blocked.kind == :request_clarification
    assert blocked.message =~ "insurance"
  end

  test "registration and the original goal survive a long dialogue and overwritten clarifications" do
    memory = start_supervised!(BookingDesk.Conversation)

    first = %Parlora.ContextSnapshot{
      session_id: "long-registration",
      revision: 2,
      pending_delegations: %{"d" => %{status: :pending, received_at_us: 1}},
      transcripts: [
        %{speaker: :user, delta: "Jamie Rivera", arrival_order: 2},
        %{speaker: :assistant, delta: "Your full name and date of birth?", arrival_order: 1}
      ]
    }

    opts = [conversation: memory, coalesce_ms: 0]

    assert {:ok, [waiting]} =
             BookingDesk.Policy.interpret(
               first,
               %ContextTrigger{kind: :delegation},
               opts ++
                 [
                   judge: fn _ ->
                     {:incomplete,
                      %{"intent" => "reschedule", "date" => "2026-11-05", "clinician" => "lee"},
                      ["time"]}
                   end,
                   identity_extractor: fn _ ->
                     {:incomplete, [:dob], %{name: "jamie rivera", name_evidence: "Jamie Rivera"}}
                   end
                 ]
             )

    assert waiting.kind == :wait_for_context

    later = %{
      first
      | revision: 50,
        transcripts: long_dialogue("March twelfth, nineteen ninety", 50)
    }

    output = %{
      "status" => "complete",
      "full_name" => "Jamie Rivera",
      "name_evidence" => "Jamie Rivera",
      "dob" => "1990-03-12",
      "dob_evidence" => ["March twelfth, nineteen ninety"]
    }

    assert {:ok, [waiting]} =
             BookingDesk.Policy.interpret(
               later,
               %ContextTrigger{kind: :delegation},
               opts ++
                 [
                   judge: fn state ->
                     refute Enum.any?(state.dialogue, &String.contains?(&1.text, "Jamie"))
                     assert state.conversation.goal == "reschedule"
                     assert state.retained_identity.name == "jamie rivera"
                     {:error, :uncertain}
                   end,
                   identity_extractor: &BookingDesk.Identity.validate(output, &1)
                 ]
             )

    assert waiting.kind == :wait_for_context

    latest = %{later | revision: 51, transcripts: long_dialogue("Please find my record", 51)}

    assert {:ok, [lookup]} =
             BookingDesk.Policy.interpret(
               latest,
               %ContextTrigger{kind: :delegation},
               opts ++
                 [
                   judge: fn state ->
                     {:ok, Map.put(state.pending_request, "intent", "lookup")}
                   end,
                   identity_extractor: fn state ->
                     assert state.retained_identity.dob == "1990-03-12"

                     BookingDesk.Identity.validate(
                       %{output | "dob_evidence" => ["1990-03-12"]},
                       state
                     )
                   end
                 ]
             )

    assert lookup.input.operation == "lookup"
    assert lookup.input.name == "jamie rivera"
    assert lookup.input.date == "2026-11-05"
    assert lookup.input.clinician == "lee"

    assert BookingDesk.Conversation.context(BookingDesk.Conversation.attach(latest, opts)).goal ==
             "reschedule"
  end

  test "an insurer supplied during uncertain intent survives until explicitly selected" do
    session = "carrier-retention"
    id = "carrier-retention-lookup"

    BookingDesk.Store.execute(
      %{operation: "lookup", name: "Jamie Rivera", dob: "1990-03-12", session: session},
      id
    )

    memory = start_supervised!(BookingDesk.Conversation)

    s = %Parlora.ContextSnapshot{
      session_id: session,
      revision: 2,
      application_context: %{lookup_request: id},
      tasks: %{
        "t" => %{
          id: "t",
          revision: 1,
          status: :completed,
          request_ids: [id],
          input: %{operation: "lookup", cursor: 1, date: "2026-11-05", clinician: "lee"}
        }
      },
      transcripts: [%{speaker: :user, delta: "I switched to Cigna", arrival_order: 2}],
      pending_delegations: %{"d" => %{status: :pending, received_at_us: 1}}
    }

    opts = [conversation: memory, coalesce_ms: 0]

    assert {:ok, [waiting]} =
             BookingDesk.Policy.interpret(
               s,
               %ContextTrigger{kind: :delegation},
               opts ++
                 [
                   judge: fn _ -> {:error, :uncertain} end,
                   insurance_extractor: fn _ -> {:ok, %{carrier: "Cigna"}} end
                 ]
             )

    assert waiting.kind == :wait_for_context
    refute BookingDesk.Store.insurance(id, session).confirmed

    s = %{s | revision: 50, transcripts: long_dialogue("Use that plan", 50)}

    assert {:ok, [review]} =
             BookingDesk.Policy.interpret(
               s,
               %ContextTrigger{kind: :delegation},
               opts ++
                 [
                   judge: fn state ->
                     assert state.conversation.carrier == "Cigna"
                     refute state.insurance.confirmed
                     {:ok, %{"intent" => "insurance_update"}}
                   end,
                   insurance_extractor: fn _ -> {:incomplete, [:carrier]} end
                 ]
             )

    assert review.input.operation == "insurance"
    assert review.input.carrier == "Cigna"
    assert review.input.response == "updated"
  end

  test "additional searches keep earlier verified offers available for a later period choice" do
    s = snapshot()
    context = s.application_context

    tasks =
      Map.new([{30, "2026-11-04"}, {31, "2026-11-05"}], fn {cursor, date} ->
        input =
          Map.merge(context, %{
            operation: "availability",
            patient: "p_1002",
            session: "test",
            cursor: cursor,
            date: date,
            clinician: "lee",
            search_intent: if(cursor == 31, do: "additional_search", else: "availability")
          })

        execute(input, "retained-offers-#{cursor}")
        id = "search-#{cursor}"
        {id, %{id: id, revision: 1, status: :completed, input: input}}
      end)

    s = %{s | tasks: tasks, transcripts: long_dialogue("The morning one on Wednesday", 50)}

    assert {:ok, [proposal]} =
             BookingDesk.Policy.interpret(s, %ContextTrigger{kind: :delegation},
               coalesce_ms: 0,
               settle_choice_ms: 0,
               judge: fn state ->
                 assert Enum.any?(state.verified_offers, &(&1.date == "2026-11-04"))
                 assert Enum.any?(state.verified_offers, &(&1.date == "2026-11-05"))

                 answers =
                   Map.new(
                     %{
                       "intent" => "choose_slot",
                       "date" => "2026-11-04",
                       "clinician" => "lee",
                       "time" => "morning",
                       "slot" => "2026-11-04/lee/10:15"
                     },
                     fn {key, value} ->
                       {key, %{choice: value, probabilities: %{value => 0.99}}}
                     end
                   )

                 BookingDesk.Judgment.decode(answers, state)
               end
             )

    assert proposal.input.operation == "propose"
    assert proposal.input.slot == "2026-11-04T10:15:00"
    assert proposal.input.search_cursor == 30
  end

  defp long_dialogue(text, cursor) do
    [
      %{speaker: :user, delta: text, arrival_order: cursor}
      | Enum.map((cursor - 1)..(cursor - 24)//-1, fn order ->
          %{
            speaker: if(rem(order, 2) == 0, do: :user, else: :assistant),
            delta: "Thanks.",
            arrival_order: order
          }
        end)
    ]
  end

  test "memory revision bookkeeping cannot cause repeated classification of unchanged caller state" do
    memory = start_supervised!(BookingDesk.Conversation)
    owner = self()
    s = snapshot()

    opts = [
      conversation: memory,
      coalesce_ms: 0,
      judge: fn state ->
        BookingDesk.Judgment.classify(state,
          evaluator: fn _ ->
            send(owner, :classified_once)
            {:error, :uncertain}
          end
        )
      end
    ]

    assert {:ok, _} = BookingDesk.Policy.interpret(s, %ContextTrigger{kind: :delegation}, opts)

    assert {:ok, _} =
             BookingDesk.Policy.interpret(
               %{s | revision: s.revision + 1},
               %ContextTrigger{kind: :delegation},
               opts
             )

    assert_receive :classified_once
    refute_receive :classified_once, 20
  end

  test "registration completion resumes the retained corrected search rather than old task parameters" do
    memory = start_supervised!(BookingDesk.Conversation)
    opts = [conversation: memory]
    s = snapshot("insurance")
    s = put_in(s.tasks["t"].status, :completed)
    s = put_in(s.tasks["t"].input.cursor, 8)
    current = BookingDesk.Conversation.attach(s, opts)

    BookingDesk.Conversation.remember(current, opts,
      judgment:
        {:incomplete,
         %{
           "intent" => "unknown",
           "date" => "2026-11-05",
           "clinician" => "patel",
           "time" => "14:00"
         }, ["intent"]}
    )

    assert {:ok, [search]} =
             BookingDesk.Policy.interpret(s, %ContextTrigger{kind: :backend_completed}, opts)

    assert search.input.operation == "availability"
    assert search.input.date == "2026-11-05"
    assert search.input.clinician == "patel"
  end

  test "the initial request is remembered before any provider delegation without admitting work" do
    memory = start_supervised!(BookingDesk.Conversation)

    s = %Parlora.ContextSnapshot{
      session_id: "early-request",
      provider_generation: 0,
      revision: 1,
      transcripts: [
        %{speaker: :user, delta: "Reschedule with Dr. Lee on November fifth", arrival_order: 1}
      ]
    }

    opts = [
      conversation: memory,
      coalesce_ms: 0,
      judge: fn _ ->
        {:incomplete, %{"intent" => "reschedule", "date" => "2026-11-05", "clinician" => "lee"},
         ["time"]}
      end
    ]

    assert {:ok, []} =
             BookingDesk.Policy.interpret(s, %ContextTrigger{kind: :transcript_updated}, opts)

    data = BookingDesk.Conversation.context(BookingDesk.Conversation.attach(s, opts))
    assert data.goal == "reschedule"
    assert data.preferences["date"] == "2026-11-05"
    assert data.preferences["clinician"] == "lee"
  end

  test "a retained offer for another doctor on the same date keeps its own verification" do
    s = snapshot()

    tasks =
      Map.new([{3000, "patel"}, {3001, "lee"}], fn {cursor, clinician} ->
        input =
          Map.merge(s.application_context, %{
            operation: "availability",
            patient: "p_1002",
            session: "test",
            cursor: cursor,
            date: "2026-11-04",
            clinician: clinician,
            search_intent: if(cursor == 3001, do: "additional_search", else: "availability")
          })

        execute(input, "retained-doctor-#{cursor}")
        id = "doctor-#{cursor}"
        {id, %{id: id, revision: 1, status: :completed, input: input}}
      end)

    s = %{
      s
      | tasks: tasks,
        transcripts: [%{speaker: :user, delta: "Dr. Patel in the morning", arrival_order: 3002}]
    }

    assert {:ok, [proposal]} =
             BookingDesk.Policy.interpret(s, %ContextTrigger{kind: :delegation},
               coalesce_ms: 0,
               settle_choice_ms: 0,
               judge: fn state ->
                 answers =
                   Map.new(
                     %{
                       "intent" => "choose_slot",
                       "date" => "2026-11-04",
                       "clinician" => "patel",
                       "time" => "morning",
                       "slot" => "2026-11-04/patel/10:15"
                     },
                     fn {key, value} ->
                       {key, %{choice: value, probabilities: %{value => 0.99}}}
                     end
                   )

                 BookingDesk.Judgment.decode(answers, state)
               end
             )

    assert proposal.input.operation == "propose"
    assert proposal.input.slot == "2026-11-04T10:15:00@patel"
    assert proposal.input.search_cursor == 3000
  end

  test "registration evidence survives a pending extractor and later dialogue before delegation" do
    memory = start_supervised!(BookingDesk.Conversation)

    first = %Parlora.ContextSnapshot{
      session_id: "pending-registration",
      provider_generation: 0,
      revision: 2,
      transcripts: [
        %{speaker: :user, delta: "Jamie Rivera", arrival_order: 2},
        %{speaker: :assistant, delta: "Your full name and date of birth?", arrival_order: 1}
      ]
    }

    opts = [conversation: memory, coalesce_ms: 0, judge: fn _ -> {:error, :uncertain} end]

    assert {:ok, []} =
             BookingDesk.Policy.interpret(
               first,
               %ContextTrigger{kind: :transcript_updated},
               opts ++ [identity_extractor: fn _ -> :pending end]
             )

    later = %{
      first
      | revision: 50,
        transcripts: long_dialogue("March twelfth, nineteen ninety", 50)
    }

    output = %{
      "status" => "complete",
      "full_name" => "Jamie Rivera",
      "name_evidence" => "Jamie Rivera",
      "dob" => "1990-03-12",
      "dob_evidence" => ["March twelfth, nineteen ninety"]
    }

    assert {:ok, []} =
             BookingDesk.Policy.interpret(
               later,
               %ContextTrigger{kind: :transcript_updated},
               opts ++
                 [
                   identity_extractor: fn state ->
                     assert state.retained_identity == %{}
                     assert "Jamie Rivera" in state.retained_registration
                     refute Enum.any?(state.dialogue, &String.contains?(&1.text, "Jamie"))
                     BookingDesk.Identity.validate(output, state)
                   end
                 ]
             )

    retained = BookingDesk.Conversation.context(BookingDesk.Conversation.attach(later, opts))
    assert retained.identity == %{name: "jamie rivera", dob: "1990-03-12"}
    assert BookingDesk.Policy.patient(later) == nil
  end
end
