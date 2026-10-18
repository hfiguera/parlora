# Run with mix run --no-start from the standalone consumer. No API calls.
alias Parlora.{ContextSnapshot, ContextTrigger}

{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, store} = OrderDesk.Store.start_link(path: ":memory:")

evidence =
  __DIR__
  |> Path.join("results-after-overflow-fix/1-corrections.json")
  |> File.read!()
  |> Jason.decode!()

transcripts =
  evidence["events"]
  |> Enum.filter(&(&1["type"] == "transcript" and &1["payload"]["speaker"] == "user"))
  |> Enum.with_index(1)
  |> Enum.map(fn {event, index} ->
    %{speaker: :user, delta: event["payload"]["delta"], arrival_order: index}
  end)
  |> Enum.reverse()

text = OrderDesk.CallerHistory.text(transcripts)
" Check order one-twenty three" = text
["123"] = OrderDesk.Speech.numbers(text)
false = OrderDesk.Speech.open_number?(text)
["123"] = OrderDesk.Speech.numbers("Check order one hundred twenty three")
["123"] = OrderDesk.Speech.numbers("Check order one two three")

snapshot = %ContextSnapshot{
  session_id: "offline-number-replay",
  application_context: %{actor: "test"},
  transcripts: transcripts,
  tasks: %{},
  pending_delegations: %{"delegation" => %{status: :pending}}
}

# Verify the actual classifier boundary, then simulate selection of its supported ID.
# This checks preprocessing and admission without a paid API call.
classify = fn state ->
  ["123"] = state.order_candidates
  choices = OrderDesk.Interpretation.questions(state)["target"].criteria
  ["123", "unknown"] = choices |> Map.keys() |> Enum.sort()
  {:ok, %{intent: "status", order: "123"}}
end

{:ok, [decision]} =
  OrderDesk.AppPolicy.interpret(snapshot, %ContextTrigger{}, classify: classify)

:start_task = decision.kind
"123" = decision.input.order
"status" = decision.input.operation

IO.puts("Verified recorded caller deltas: #{String.trim(text)}")
IO.puts("Candidate 123 reaches the TypeSafe target question; the policy admits its lookup.")
GenServer.stop(store)
