defmodule BookingDesk.ApprovalPolicyTest do
  use ExUnit.Case, async: false
  alias BookingDesk.{Policy, Store}
  alias Parlora.{ContextSnapshot, ContextTrigger}

  setup do
    db = :sys.get_state(Store)
    {:ok, saved} = Exqlite.Sqlite3.serialize(db)
    on_exit(fn -> :ok = Exqlite.Sqlite3.deserialize(db, saved) end)
    %{snapshot: snapshot()}
  end

  defp snapshot do
    session = "approval-policy"

    Store.execute(
      %{operation: "lookup", session: session, name: "Jamie Rivera", dob: "1990-03-12"},
      "approval-lookup"
    )

    insurer = Store.insurance("approval-lookup", session)

    identity = %{
      session: session,
      patient: "p_1002",
      lookup_request: "approval-lookup",
      insurance_request: "approval-insurance"
    }

    Store.execute(
      Map.merge(identity, %{
        operation: "insurance",
        response: "unchanged",
        carrier: insurer.carrier,
        insurance_revision: insurer.revision
      }),
      "approval-insurance"
    )

    Store.execute(
      Map.merge(identity, %{
        operation: "availability",
        date: "2026-11-05",
        clinician: "lee",
        cursor: 29
      }),
      "approval-search"
    )

    input =
      Map.merge(identity, %{
        operation: "propose",
        slot: "2026-11-05T10:15:00",
        change: "book",
        revision: 30,
        cursor: 30,
        search_cursor: 29,
        clinician: "lee"
      })

    assert %{"status" => "completed"} = Store.execute(input, "approval-proposal")

    parts = [
      {:assistant, "Shall I book November fifth at 10:15 AM with Dr. Lee?", 31, 70_000},
      {:user, "Yes, please", 32, 74_000},
      {:assistant, "Okay. Processing that now.", 33, 75_000},
      {:user, "'Kay", 34, 76_800}
    ]

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

    %ContextSnapshot{
      session_id: session,
      provider_generation: 0,
      application_context: identity,
      transcripts: transcripts,
      tasks: %{
        "proposal-task" => %{
          id: "proposal-task",
          revision: 1,
          status: :completed,
          input: input,
          request_ids: ["approval-proposal"]
        }
      },
      pending_delegations: %{"approval-call" => %{status: :pending, received_at_us: 1}}
    }
  end

  defp result,
    do:
      {:ok,
       %{"intent" => "confirm", "date" => "2026-11-05", "time" => "10:15", "clinician" => "lee"}}

  defp interpret(snapshot, result, opts \\ []) do
    Policy.interpret(
      snapshot,
      %ContextTrigger{kind: :delegation},
      Keyword.merge(
        [
          approval_continuity: true,
          coalesce_ms: 0,
          settle_confirm_ms: 0,
          approval_readback_judge: fn _ -> {:ok, :ready} end,
          judge: fn _ -> result end
        ],
        opts
      )
    )
  end

  test "only the exact current proposal can be admitted from continued approval", %{snapshot: s} do
    assert {:ok, [decision]} = interpret(s, result())
    assert decision.kind == :start_task
    assert decision.input.operation == "confirm"
    assert decision.input.proposal == "approval-proposal"
    assert decision.input.revision == 30

    for mismatch <- [%{"date" => "2026-11-04"}, %{"time" => "14:00"}, %{"clinician" => "patel"}] do
      {:ok, fields} = result()
      assert {:ok, decisions} = interpret(s, {:ok, Map.merge(fields, mismatch)})
      refute Enum.any?(decisions, &(&1.kind == :start_task))
    end
  end

  test "high model confidence cannot override a refusal, condition, correction or question", %{
    snapshot: s
  } do
    for {approval, latest} <- [
          {"Yes, please", "No, don't book it"},
          {"Yes, please", "Wait"},
          {"Yes, please", "Yes, but wait"},
          {"Yes, please", "Actually November fourth"},
          {"Yes, please", "Okay?"},
          {"Yes, if covered", "'Kay"},
          {"No", "'Kay"},
          {"Yes?", "'Kay"}
        ] do
      current =
        update_in(
          s.transcripts,
          &Enum.map(&1, fn part ->
            case part.arrival_order do
              32 -> %{part | delta: approval}
              34 -> %{part | delta: latest}
              _ -> part
            end
          end)
        )

      assert {:ok, decisions} = interpret(current, result())
      refute Enum.any?(decisions, &(&1.kind in [:start_task, :supersede_task]))
    end
  end

  test "low confidence and unavailable readback checks cannot authorize continued approval", %{
    snapshot: s
  } do
    for failed <- [{:error, :uncertain}, {:error, :unavailable}] do
      assert {:ok, decisions} =
               interpret(s, result(), approval_readback_judge: fn _ -> failed end)

      refute Enum.any?(decisions, &(&1.kind == :start_task))
    end

    for key <- ~w(intent date time clinician) do
      {:ok, fields} = result()

      answers =
        Map.new(fields, fn {k, value} ->
          {k, %{choice: value, probabilities: %{value => if(k == key, do: 0.84, else: 0.99)}}}
        end)

      assert {:ok, decisions} = interpret(s, BookingDesk.Judgment.decode(answers))
      refute Enum.any?(decisions, &(&1.kind == :start_task))
    end
  end

  test "older provider speech and other-provider defaults never inherit this approval", %{
    snapshot: s
  } do
    for current <- [s, %{s | provider_generation: 1}] do
      opts = if current == s, do: [approval_continuity: false], else: []
      assert {:ok, decisions} = interpret(current, result(), opts)
      refute Enum.any?(decisions, &(&1.kind == :start_task))
    end

    bare = %{s | transcripts: Enum.reject(s.transcripts, &(&1.arrival_order == 32))}
    assert {:ok, decisions} = interpret(bare, result())
    refute Enum.any?(decisions, &(&1.kind == :start_task))
  end
end
