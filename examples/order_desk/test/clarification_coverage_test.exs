defmodule OrderDesk.ClarificationCoverageTest do
  use ExUnit.Case, async: true
  alias OrderDesk.{Clarification, ClarificationCoverage, Interpretation, Recovery}
  alias Parlora.{ContextDecision, ContextSnapshot}

  defp snapshot do
    %ContextSnapshot{
      session_id: Parlora.ID.new(),
      provider_speech: :idle,
      application_context: %{voice_provider: :gemini},
      transcripts: [
        %{speaker: :assistant, delta: "Would you like to hear the items?", arrival_order: 3},
        %{speaker: :user, delta: "Check my order", arrival_order: 2}
      ]
    }
  end

  defp question do
    %ContextDecision{
      kind: :request_clarification,
      task_id: "task",
      expected_task_revision: 1,
      message: "Which order number?",
      input: %{missing: ["order"]}
    }
  end

  defp coordinate(snapshot, result, remaining \\ 8_000) do
    Clarification.coordinate({:ok, [question()]}, snapshot,
      clarification_judge: fn state ->
        assert state.proposed.input == %{missing: ["order"]}
        assert List.first(state.recent_dialogue).speaker == :user
        result
      end,
      clarification_window: fn _ -> remaining end
    )
  end

  test "semantic different overrides the question-mark fallback; covered only defers" do
    assert {:ok, [decision]} = coordinate(snapshot(), {:ok, "different"})
    assert decision == question()
    assert {:ok, [wait]} = coordinate(snapshot(), {:ok, "covered"})

    assert %{
             kind: :wait_for_context,
             recheck_after_ms: 8_000,
             recheck_key: "2:coverage",
             message: nil
           } = wait

    assert wait.task_id == "task"
    assert wait.expected_task_revision == 1
  end

  test "timeout and uncertainty retain a bounded fallback and deadline expiry skips inference" do
    for result <- [{:error, :timeout}, {:error, :uncertain}, {:error, :unavailable}] do
      assert {:ok, [%{kind: :wait_for_context, recheck_after_ms: 300}]} =
               coordinate(snapshot(), result, 300)
    end

    assert {:ok, [decision]} =
             Clarification.coordinate({:ok, [question()]}, snapshot(),
               clarification_window: fn _ -> 0 end,
               clarification_judge: fn _ -> flunk("No inference after the absolute deadline") end
             )

    assert decision == question()
  end

  test "no semantic call while speaking, after new caller input, during save hold or for OpenAI" do
    s = snapshot()

    for candidate <- [
          %{s | provider_speech: :speaking},
          %{s | transcripts: [%{speaker: :user, delta: "123", arrival_order: 4} | s.transcripts]},
          %{s | application_context: %{voice_provider: :openai}},
          put_in(
            s.application_context[:save_announcement_until_ms],
            System.monotonic_time(:millisecond) + 500
          )
        ] do
      assert {:ok, [_]} =
               Clarification.coordinate({:ok, [question()]}, candidate,
                 clarification_judge: fn _ -> flunk("Ineligible semantic request") end,
                 clarification_window: fn _ -> flunk("Ineligible suppression window") end
               )
    end

    action = %{question() | kind: :supersede_task}

    assert {:ok, [^action]} =
             Clarification.coordinate({:ok, [action]}, s,
               clarification_judge: fn _ -> flunk("Never judge business decisions") end
             )
  end

  test "expiry does not restart the settle/verify loop or renew when a duplicate call arrives" do
    entry = %{revision: 1, context_wait: %{expired?: true, recheck_key: "2:coverage"}}
    recovery = Recovery.new({"task", entry}, nil, 2, [])
    assert [%{kind: :request_clarification}] = Recovery.decide(recovery, "Which number?")
    pending = put_in(recovery.entry.context_wait.expired?, false)

    assert [%{kind: :wait_for_context, recheck_after_ms: nil}] =
             Recovery.decide(pending, "Which number?")

    owner = self()

    options = [
      clarification_window: fn key ->
        send(owner, {:key, key})
        0
      end
    ]

    s = snapshot()

    for id <- ["original", "duplicate"] do
      assert {:ok, [_]} =
               Clarification.coordinate({:ok, [%{question() | delegation_id: id}]}, s, options)
    end

    assert_receive {:key, key}
    assert_receive {:key, ^key}
  end

  test "window retains its original deadline and fails open on capacity exhaustion" do
    {:ok, pid} = GenServer.start_link(Interpretation, [])
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    key = {:session, 2, {:task, "task", 1}}
    assert Interpretation.coordination_window(key, pid) == 8_000
    due = :sys.get_state(pid).windows[key]
    assert Interpretation.coordination_window(key, pid) in 1..8_000
    assert :sys.get_state(pid).windows[key] == due

    :sys.replace_state(pid, fn state ->
      put_in(state.windows[key], {System.monotonic_time(:millisecond) - 1, elem(due, 1)})
    end)

    assert Interpretation.coordination_window(key, pid) == 0

    for n <- 1..127,
        do: assert(Interpretation.coordination_window({:session, n, :other}, pid) == 8_000)

    assert Interpretation.coordination_window(:overflow, pid) == 0
    assert map_size(:sys.get_state(pid).windows) == 128
  end

  test "inference time consumes the waiting budget" do
    clock = start_supervised!({Agent, fn -> [600, 120] end})

    assert {:ok, [%{recheck_after_ms: 120}]} =
             Clarification.coordinate({:ok, [question()]}, snapshot(),
               clarification_window: fn _ ->
                 Agent.get_and_update(clock, fn [n | rest] -> {n, rest} end)
               end,
               clarification_judge: fn _ -> {:ok, "covered"} end
             )
  end

  test "thresholds reject incomplete or low-confidence model answers" do
    covered = %{choice: "covered", probabilities: %{"covered" => 0.99}}
    assert ClarificationCoverage.interpret_pair(%{"coverage" => covered}) == {:error, :uncertain}

    assert ClarificationCoverage.interpret_pair(%{
             "coverage" => covered,
             "request" => %{choice: "request", probabilities: %{"request" => 0.84}}
           }) == {:error, :uncertain}
  end

  test "application policy submits a fresh clarification after a coverage wait expires" do
    s = %{
      snapshot()
      | tasks: %{
          "task" => %{
            revision: 1,
            status: :completed,
            input: %{order: "124", operation: "items", instructions: nil, user_revision: 1},
            context_wait: %{expired?: true, recheck_key: "2:coverage"}
          }
        }
    }

    assert {:ok, [%{kind: :request_clarification, message: message}]} =
             OrderDesk.AppPolicy.interpret(
               s,
               %Parlora.ContextTrigger{kind: :context_wait_expired},
               classify: fn _ -> {:ok, %{intent: "delivery", order: "124"}} end,
               clarification_window: fn _ -> 0 end,
               clarification_judge: fn _ -> flunk("Expired wait cannot be renewed by JEV") end
             )

    assert message =~ "new edit request is missing its delivery wording"
  end
end
