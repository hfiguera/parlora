defmodule OrderDesk.StreamingClarificationTest do
  use ExUnit.Case
  alias OrderDesk.{AppPolicy, Clarification, Recovery, Speech}
  alias Parlora.{ContextSnapshot, ContextTrigger}

  test "an unfinished initial request survives a clarification before any task exists" do
    initial = snapshot("Check order one two", 5)
    {:ok, [question]} = decide(initial, fn _ -> flunk("Do not execute an incomplete ID") end)
    assert question.kind == :request_clarification
    assert question.input.number_pending?
    assert question.input.request_text == "Check order one two"
    assert question.input.known_operation == nil

    for reply <- ["three", "One hundred twenty four, one two four"] do
      resumed = reply(initial, question, reply, 7)

      assert {:ok, [%{kind: :start_task, input: %{operation: "status", order: order}}]} =
               decide(resumed, fn state ->
                 assert state.clarification_reply.pending_request.request_text ==
                          "Check order one two"

                 [order] = Speech.numbers(state.new_caller_text)
                 {:ok, %{intent: "status", order: order}}
               end)

      assert order == if(reply == "three", do: "123", else: "124")
    end
  end

  test "a number prefix split by clarification is reconstructed even with overlapping assistant captions" do
    s = %ContextSnapshot{
      session_id: "split",
      pending_delegations: %{
        "d" => %{
          status: :pending,
          clarification: %{context_revision: 3, message: "Finish the number", input: %{}},
          context_wait: %{expired?: true, recheck_key: "5:verify"}
        }
      },
      transcripts: [
        %{speaker: :user, delta: " four", arrival_order: 5, start_ms: 1100, end_ms: 1600},
        %{
          speaker: :assistant,
          delta: "Thanks for the",
          arrival_order: 4,
          start_ms: 600,
          end_ms: 1300
        },
        %{
          speaker: :user,
          delta: "Sorry, I mean one hundred twenty",
          arrival_order: 3,
          start_ms: 100,
          end_ms: 1000
        }
      ]
    }

    assert {:ok, [%{kind: :start_task, input: %{order: "124"}}]} =
             decide(s, fn state ->
               assert Speech.numbers(state.new_caller_text) == ["124"]
               {:ok, %{intent: "status", order: "124"}}
             end)
  end

  test "number reconstruction does not merge new requests, full numbers or negation" do
    for reply <- [
          "124",
          "one two four",
          "no, four",
          "Actually, check 124",
          "items",
          "cancel",
          "three four",
          "123, 124"
        ] do
      assert Speech.continue_number("Check order one two", reply) == reply
    end

    assert Speech.continue_number("Check order 123", "four") == "four"
    assert Speech.continue_number("Check order one hornet twenty", "three") == "three"
  end

  test "new delegations cannot steal an outstanding recovery and terminal entries cannot own it" do
    s = snapshot("items", 8)

    owner = %{
      status: :pending,
      received_at_us: 10,
      clarification: %{
        context_revision: 6,
        message: "What about order 124?",
        input: %{known_order: "124", known_operation: nil, missing: ["operation"]}
      }
    }

    old = %{
      owner
      | received_at_us: 2,
        clarification: %{owner.clarification | context_revision: 3, input: %{}}
    }

    s = %{
      s
      | pending_delegations: %{
          "old" => old,
          "owner" => owner,
          "new" => %{status: :pending, received_at_us: 100},
          "done" => %{owner | status: :claimed}
        }
    }

    for trigger <- ["new", "old", nil] do
      assert {:ok, [%{kind: :start_task, delegation_id: "owner"} | _recheck]} =
               AppPolicy.interpret(s, %ContextTrigger{kind: :delegation, delegation_id: trigger},
                 classify: fn state ->
                   assert state.clarification_reply.pending_request.known_order == "124"
                   {:ok, %{intent: "items", order: "124"}}
                 end
               )
    end

    assert {"new", _} =
             Recovery.pending(%{
               s
               | pending_delegations: Map.drop(s.pending_delegations, ["owner", "old"])
             })
  end

  test "uncertain items proposes targeted confirmation without dispatching a lookup" do
    s = snapshot("Do you know what items ordered", 5)

    {:ok, [question]} =
      decide(s, fn _ ->
        {:error, {:uncertain, %{intent: "items", order: "124", uncertain_fields: ["intent"]}}}
      end)

    assert question.kind == :request_clarification
    assert question.message == "Do you mean the items for order 124?"
    assert question.input.candidate_operation == "items"
    assert question.input.known_operation == nil

    for {reply, result, kind} <- [
          {"Yes, the items", {:ok, %{intent: "items", order: "124"}}, :start_task},
          {"No, delivery status", {:ok, %{intent: "status", order: "124"}}, :start_task},
          {"No", {:ok, %{intent: "none", order: "unknown"}}, nil}
        ] do
      {:ok, decisions} =
        decide(reply(s, question, reply, 7), fn state ->
          assert state.clarification_reply.pending_request.candidate_operation == "items"
          result
        end)

      if kind, do: assert(hd(decisions).kind == kind), else: assert(decisions == [])
    end
  end

  test "a number correcting a proposed read reaches interpretation without authorizing the proposal" do
    for operation <- ["status", "items", "instructions"] do
      s = snapshot("Check my order", 5)

      {:ok, [question]} =
        decide(s, fn _ ->
          {:error, {:uncertain, %{intent: operation, order: "134", uncertain_fields: ["intent"]}}}
        end)

      resumed = reply(s, question, "One hundred twenty four", 7)

      assert {:ok, [%{kind: :start_task, input: %{operation: ^operation, order: "124"}}]} =
               decide(resumed, fn state ->
                 assert state.clarification_reply.number_reply == "124"
                 assert state.clarification_reply.pending_request.candidate_operation == operation
                 {:ok, %{intent: operation, order: "124"}}
               end)

      assert {:ok, [%{kind: :request_clarification}]} =
               decide(resumed, fn _ ->
                 {:error,
                  {:uncertain, %{intent: operation, order: "124", uncertain_fields: ["intent"]}}}
               end)
    end
  end

  test "bare numbers still cannot fill an unspecified operation or authorize a write proposal" do
    for candidate <- [nil, "delivery", "refuse", "cancel"] do
      recovery = %{
        entry: %{
          clarification: %{
            input: %{
              known_order: "134",
              known_operation: nil,
              missing: ["operation"],
              candidate_operation: candidate
            }
          }
        }
      }

      assert %{known_order: "124", missing: ["operation"]} =
               Clarification.number_reply(recovery, "One hundred twenty four")
    end
  end

  test "target uncertainty is not mislabeled as a missing operation" do
    recovery = %{entry: %{clarification: %{input: %{known_order: "124"}}}}

    input =
      Clarification.input(
        %{intent: "items", order: "124", uncertain_fields: ["target"]},
        "items",
        false,
        recovery
      )

    assert input.missing == ["target_confirmation"]
    assert Clarification.question(input) == "Please confirm: do you mean the items for order 124?"
  end

  test "saved request text is bounded without truncating a request into new meaning" do
    input = Clarification.number_input(%{entry: %{}}, String.duplicate("x", 2049))
    refute Map.has_key?(input, :request_text)
    assert :erlang.external_size(input) < 4096
  end

  test "a fresh session completes a split first lookup and claims later delegations without duplicate jobs" do
    classify = fn state ->
      case Speech.numbers(state.new_caller_text) do
        [order] ->
          {:ok, %{intent: "status", order: order}}

        _ ->
          {:error,
           {:uncertain, %{intent: "status", order: "unknown", uncertain_fields: ["target"]}}}
      end
    end

    {:ok, session} =
      OrderDesk.start_session(
        {Parlora.Channels.LocalAudio, device: :synthetic},
        {OrderDesk.ScriptedProvider, observer: self(), audio: false},
        context_policy:
          {AppPolicy,
           [
             classify: classify,
             number_settle_ms: 30,
             clarification_settle_ms: 40,
             clarification_verify_ms: 30
           ]}
      )

    on_exit(fn -> if Process.alive?(session), do: Parlora.close(session, :cancel) end)
    assert_receive {:scripted_provider, provider}

    receive do
      {:parlora_event, %{source: :session, type: :ready}} -> :ok
    after
      1000 -> flunk("Not ready")
    end

    OrderDesk.ScriptedProvider.say(provider, "Check order one two")
    OrderDesk.ScriptedProvider.delegate(provider, "first")

    receive do
      {:parlora_event, %{type: :clarification_requested}} -> :ok
    after
      1500 -> flunk("No question")
    end

    assert map_size(Parlora.status(session).jobs) == 0

    OrderDesk.ScriptedProvider.transcript(provider, %{
      speaker: :assistant,
      delta: "Finish the number"
    })

    OrderDesk.ScriptedProvider.delegate(provider, "another")
    OrderDesk.ScriptedProvider.say(provider, "three")

    receive do
      {:parlora_event, %{type: :task_submitted, payload: %{request: request}}} ->
        assert request.input.order == "123"
        assert request.delegation_id == "first"
    after
      1500 -> flunk("Number continuation did not start work")
    end

    receive do
      {:parlora_event, %{type: :delegation_associated}} -> :ok
    after
      1500 -> flunk("Duplicate delegation not associated")
    end

    assert map_size(Parlora.status(session).jobs) == 1
  end

  defp snapshot(text, revision) do
    %ContextSnapshot{
      session_id: "initial",
      transcripts: [%{speaker: :user, delta: text, arrival_order: revision}],
      pending_delegations: %{
        "d" => %{
          status: :pending,
          context_wait: %{recheck_key: "#{revision}:verify", expired?: true}
        }
      }
    }
  end

  defp reply(s, question, text, revision) do
    entry = s.pending_delegations["d"]
    marker = %{context_revision: revision - 2, input: question.input, message: question.message}

    %{
      s
      | pending_delegations: %{
          "d" =>
            Map.merge(entry, %{
              clarification: marker,
              context_wait: %{recheck_key: "#{revision}:verify", expired?: true}
            })
        },
        transcripts: [%{speaker: :user, delta: text, arrival_order: revision} | s.transcripts]
    }
  end

  defp decide(s, classify), do: AppPolicy.interpret(s, %ContextTrigger{}, classify: classify)
end
