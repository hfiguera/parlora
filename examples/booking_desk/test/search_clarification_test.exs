defmodule BookingDesk.SearchClarificationTest do
  use ExUnit.Case, async: true
  alias BookingDesk.SearchClarification
  alias Parlora.ContextSnapshot

  setup do
    task = %{
      id: "search",
      revision: 1,
      input: %{operation: "availability", date: "2026-11-04", clinician: "lee", cursor: 2}
    }

    preferences = %{"date" => "2026-11-05", "clinician" => "lee"}
    snapshot = %ContextSnapshot{session_id: "clarification", provider_generation: 0}
    {question, action} = SearchClarification.offer(snapshot, task, preferences, 8)

    task =
      Map.put(task, :clarification, %{
        input: %{
          booking_request: preferences,
          lookup_request: "lookup",
          search_clarification: action
        }
      })

    snapshot = %{
      snapshot
      | tasks: %{task.id => task},
        transcripts: [
          part(:user, "Yes", 20, 74_200, 74_400),
          part(:assistant, question, 10, 63_400, 72_000),
          part(:user, "It's possible to change the day to November fifth", 8, 58_800, 62_800)
        ]
    }

    %{snapshot: snapshot, task: task, preferences: preferences, question: question}
  end

  test "a fresh affirmative resumes only the scoped read-only replacement search", fixture do
    assert fixture.question =~ "replace the current search"
    assert fixture.question =~ "November 5, 2026"
    assert fixture.question =~ "Dr. Lee"
    refute fixture.question =~ " or "

    for text <- ["Yes", "yes, please!", "Yeah", "Sure", "Please do", "Go ahead"] do
      assert {:ok, judgment} = reply(fixture, text)

      assert judgment == %{
               "intent" => "replace_search",
               "date" => "2026-11-05",
               "clinician" => "lee"
             }
    end
  end

  test "the recorded spoken question survives trailing assistant acknowledgments", fixture do
    question =
      "Alright, I've got November fifth with Dr. Lee in mind. Would you like me to check availability for that?"

    snapshot = put_question(fixture.snapshot, question)

    snapshot = %{
      snapshot
      | transcripts: [
          part(:assistant, "Okay. Checking now.", 21, 75_200, 76_400) | snapshot.transcripts
        ]
    }

    assert {:ok, %{"date" => "2026-11-05"}} =
             SearchClarification.reply(
               snapshot,
               fixture.task,
               "lookup",
               fixture.preferences,
               20,
               "Yes",
               clarification_judge: fn state ->
                 assert state.spoken_question == question
                 assert state.expected_question == fixture.question
                 {:ok, :accept}
               end
             )
  end

  test "negation, conditions, questions and proposed writes cannot answer the search question",
       fixture do
    for text <- [
          "Yes, if it is covered",
          "Yes, unless it costs extra",
          "Maybe",
          "Yes?",
          "Yes, but wait",
          "Yes, November sixth instead",
          "No. Yes",
          "Yes, please book it",
          "Please cancel it",
          "Yes, send a reminder"
        ] do
      assert :unresolved = reply(fixture, text)
    end
  end

  test "refusing the exact question is a decline rather than another uncertainty loop", fixture do
    assert {:decline, %{date: "2026-11-05"}} = reply(fixture, "No")
  end

  test "a short reply cannot answer another kind of question or another date or doctor",
       fixture do
    for question <- [
          "I have Aetna on file. Is that still your insurance?",
          "November fifth with Dr. Lee. Shall I book that?",
          "Check availability for November fifth with Dr. Lee or book a time?",
          "Should I not check availability for November fifth with Dr. Lee?",
          "Should I check availability for November fourth with Dr. Lee?",
          "Should I check availability for November fifth with Dr. Patel?",
          "Should I check availability for that?",
          "I'm on it."
        ] do
      changed = %{fixture | snapshot: put_question(fixture.snapshot, question)}
      assert :unresolved = reply(changed, "Yes")
    end
  end

  test "lookup, task revision, generation and retained corrections fence the reply", fixture do
    for changed <- [
          %{fixture | task: %{fixture.task | revision: 2}},
          %{fixture | task: %{fixture.task | id: "different"}},
          %{fixture | snapshot: %{fixture.snapshot | provider_generation: 1}},
          %{fixture | preferences: %{"date" => "2026-11-06", "clinician" => "lee"}},
          %{fixture | preferences: %{"date" => "2026-11-05", "clinician" => "patel"}},
          %{fixture | preferences: %{}}
        ] do
      assert :unresolved = reply(changed, "Yes")
    end

    assert :unresolved =
             SearchClarification.reply(
               fixture.snapshot,
               fixture.task,
               "another-lookup",
               fixture.preferences,
               20,
               "Yes"
             )

    assert :unresolved =
             SearchClarification.reply(
               fixture.snapshot,
               fixture.task,
               "lookup",
               fixture.preferences,
               8,
               "Yes"
             )
  end

  test "a missing or superseded spoken question cannot authorize the continuation", fixture do
    [user, assistant, earlier] = fixture.snapshot.transcripts

    for transcripts <- [
          [user],
          [user, %{assistant | arrival_order: 7}, earlier],
          [user, part(:assistant, "Is Aetna still your insurance?", 19, 73_000, 74_000), earlier]
        ] do
      changed = %{fixture | snapshot: %{fixture.snapshot | transcripts: transcripts}}
      assert :unresolved = reply(changed, "Yes")
    end
  end

  test "proposals and admitted writes cannot use a retained search continuation", fixture do
    for operation <- ~w(propose confirm reminder_confirm insurance lookup) do
      task = put_in(fixture.task, [:input, :operation], operation)
      assert :unresolved = reply(%{fixture | task: task}, "Yes")
      assert SearchClarification.offer(fixture.snapshot, task, fixture.preferences, 8) == nil
    end
  end

  test "invalid or unchanged preferences do not offer a replacement", fixture do
    for preferences <- [
          %{},
          %{"date" => "2099-01-01", "clinician" => "lee"},
          %{"date" => "2026-11-05", "clinician" => "unknown"},
          %{"date" => "2026-11-04", "clinician" => "lee"}
        ] do
      assert SearchClarification.offer(fixture.snapshot, fixture.task, preferences, 8) == nil
    end
  end

  test "all demo dates and doctor preferences can be read back without selecting a slot",
       fixture do
    for date <- BookingDesk.Store.dates(),
        clinician <- ~w(lee patel any),
        date != fixture.task.input.date or clinician != fixture.task.input.clinician do
      preferences = %{"date" => date, "clinician" => clinician, "time" => "14:00"}

      {question, action} =
        SearchClarification.offer(fixture.snapshot, fixture.task, preferences, 8)

      assert question =~ "2:00 PM"
      task = put_in(fixture.task, [:clarification, :input, :search_clarification], action)
      snapshot = put_question(fixture.snapshot, question)

      assert {:ok, %{"intent" => "replace_search", "date" => ^date, "clinician" => ^clinician}} =
               reply(%{fixture | snapshot: snapshot, task: task, preferences: preferences}, "Yes")
    end
  end

  defp reply(fixture, text) do
    SearchClarification.reply(
      fixture.snapshot,
      fixture.task,
      "lookup",
      fixture.preferences,
      20,
      text
    )
  end

  defp put_question(snapshot, question) do
    %{
      snapshot
      | transcripts:
          Enum.map(snapshot.transcripts, fn part ->
            if part.speaker == :assistant, do: %{part | delta: question}, else: part
          end)
    }
  end

  defp part(speaker, text, cursor, first, last),
    do: %{
      speaker: speaker,
      delta: text,
      arrival_order: cursor,
      provider_generation: 0,
      start_ms: first,
      end_ms: last
    }
end
