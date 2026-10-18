# Controlled diagnostic reconstruction; original wire timestamps are not available.
if Application.fetch_env!(:order_desk, :database) != ":memory:",
  do: raise("Run this diagnostic with ORDER_DESK_DATABASE=:memory:")

alias OrderDesk.{AppPolicy, CallerHistory, Speech}
alias Parlora.{ContextSnapshot, ContextTrigger}

snapshot = fn fragments, tasks, pending ->
  transcripts =
    fragments
    |> Enum.with_index(1)
    |> Enum.map(fn {{speaker, delta}, i} ->
      %{speaker: speaker, delta: delta, arrival_order: i}
    end)
    |> Enum.reverse()

  %ContextSnapshot{
    session_id: "root-cause-replay",
    transcripts: transcripts,
    tasks: tasks,
    pending_delegations: pending,
    application_context: %{actor: "root-cause-replay"}
  }
end

inspect_policy = fn label, s, judgment ->
  owner = self()

  result =
    AppPolicy.interpret(s, %ContextTrigger{},
      classify: fn input ->
        send(owner, {:input, input})
        judgment
      end
    )

  receive do
    {:input, input} ->
      IO.inspect(%{label: label, classifier_input: input, decisions: result},
        limit: :infinity,
        printable_limit: :infinity
      )
  after
    1000 -> raise "classifier not called"
  end

  result
end

browser =
  snapshot.(
    [
      {:user, " For order one hundred twenty"},
      {:assistant, "Sure."},
      {:user, " four, change the delivery instructions to leave it at reception"}
    ],
    %{},
    %{"d" => %{status: :pending, context_wait: %{expired?: true, recheck_key: "3:verify"}}}
  )

text = CallerHistory.text(browser.transcripts)

IO.inspect(%{
  label: "browser_candidates",
  text: text,
  candidates: Speech.numbers(text),
  joined_control: Speech.numbers(String.replace(text, "\n", " ")),
  suffix_rejoin:
    Speech.continue_number(
      "For order one hundred twenty",
      "four, change the delivery instructions to leave it at reception"
    )
})

{:ok, [%{kind: :request_clarification}]} =
  inspect_policy.(
    "browser_recorded_judgment",
    browser,
    {:ok, %{intent: "delivery", order: "unknown"}}
  )

{:ok, _} = OrderDesk.Store.propose("root-cause-replay", "124", "leave it at reception", "draft")
{:ok, :rejected} = OrderDesk.Store.refuse("root-cause-replay", "124", "draft")

refusal_task = %{
  "task" => %{
    revision: 2,
    status: :completed,
    input: %{
      order: "124",
      operation: "refuse",
      instructions: nil,
      proposal_id: "draft",
      user_revision: 7
    },
    context_wait: %{expired?: true, recheck_key: "9:verify"}
  }
}

refusal =
  snapshot.(
    [
      {:user, "For order 124 change the delivery instructions to leave it at reception"},
      {:assistant, "The page now has"},
      {:user, "No"},
      {:assistant, "a draft"},
      {:user, ", don't save"},
      {:assistant, "instruction"},
      {:user, " that Keep the original"},
      {:assistant, "to leave it at reception"},
      {:user, " instructions"}
    ],
    refusal_task,
    %{}
  )

{:ok, [%{kind: :request_clarification}]} =
  inspect_policy.(
    "twilio_uncertain_tail",
    refusal,
    {:error, {:uncertain, %{intent: "refuse", order: "124", uncertain_fields: ["intent"]}}}
  )

{:ok, []} =
  inspect_policy.("twilio_confident_control", refusal, {:ok, %{intent: "refuse", order: "124"}})

status_task = %{
  "task" => %{
    revision: 1,
    status: :completed,
    input: %{order: "124", operation: "status", instructions: nil, user_revision: 1}
  }
}

items =
  snapshot.(
    [
      {:user, "Check order one hundred twenty four"},
      {:assistant, "Order 124 is out for delivery"},
      {:user, "What items are in that"},
      {:assistant, "Checking"},
      {:user, " order?"}
    ],
    status_task,
    %{}
  )

{:ok, []} =
  inspect_policy.("telnyx_no_delegation", items, {:ok, %{intent: "items", order: "124"}})

{:ok, [%{kind: :start_task}]} =
  inspect_policy.(
    "telnyx_with_delegation_control",
    %{items | pending_delegations: %{"items" => %{status: :pending}}},
    {:ok, %{intent: "items", order: "124"}}
  )

if System.get_env("DIAGNOSE_LIVE_CLASSIFIER") == "1" do
  for {label, s} <- [
        {"browser_live_classifier", browser},
        {"twilio_live_classifier", refusal},
        {"telnyx_live_classifier", items}
      ] do
    result = AppPolicy.interpret(s, %ContextTrigger{}, [])
    IO.inspect(%{label: label, result: result}, limit: :infinity)
  end

  IO.puts(
    "LIVE_JUDGMENTS=" <>
      Jason.encode!(OrderDesk.Interpretation.evidence() |> Enum.filter(&(&1.kind == "judgment")))
  )
end

IO.puts("Five controlled policy replays and number-candidate comparison completed")
