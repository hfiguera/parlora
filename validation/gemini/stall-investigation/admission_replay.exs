alias Parlora.Event
owner = self()

classifier = fn _ ->
  send(owner, :classified)
  {:ok, %{intent: "status", order: "124"}}
end

{:ok, session} =
  OrderDesk.start_session(
    {Parlora.Channels.LocalAudio, device: :synthetic},
    {OrderDesk.ScriptedProvider, observer: self(), audio: false},
    context_policy: {OrderDesk.AppPolicy, [classify: classifier]}
  )

provider =
  receive do
    {:scripted_provider, pid} -> pid
  after
    2_000 -> raise "no provider"
  end

receive do
  {:parlora_event, %Event{source: :session, type: :ready}} -> :ok
after
  2_000 -> raise "not ready"
end

:ok = Parlora.expect_progress(session, "greeting", 80, until: :conversation, on_timeout: :close)

OrderDesk.ScriptedProvider.transcript(provider, %{
  speaker: :assistant,
  delta: "Hi, I can help check an order.",
  timing: :unavailable
})

OrderDesk.ScriptedProvider.transcript(provider, %{
  speaker: :user,
  delta: "Sure, check the order 124.",
  timing: :unavailable
})

Process.sleep(150)
before = Parlora.status(session)

false =
  receive do
    :classified -> true
  after
    0 -> false
  end

true =
  before.status == :ready and before.health.expectation.status == :observed and
    map_size(before.jobs) == 0

IO.puts(
  Jason.encode!(%{
    case: "caption_without_delegation",
    status: before.status,
    jobs: map_size(before.jobs),
    classifier_called: false,
    expectation: before.health.expectation,
    observations: before.health.observations
  })
)

OrderDesk.ScriptedProvider.transcript(provider, %{
  speaker: :user,
  delta: " Hello? Are you there?",
  timing: :unavailable
})

Process.sleep(150)

false =
  receive do
    :classified -> true
  after
    0 -> false
  end

true = map_size(Parlora.status(session).jobs) == 0

IO.puts(
  Jason.encode!(%{
    case: "followup_cannot_unlock_without_delegation",
    jobs: 0,
    classifier_called: false
  })
)

OrderDesk.ScriptedProvider.delegate(provider, "controlled-delegation")

receive do
  :classified -> :ok
after
  2_000 -> raise "classifier did not run"
end

receive do
  {:parlora_event, %Event{source: :session, type: :task_submitted, payload: %{request: request}}} ->
    IO.puts(
      Jason.encode!(%{
        case: "adding_missing_delegation_unlocks_lookup",
        order: request.input.order,
        operation: request.input.operation
      })
    )
after
  2_000 -> raise "no task"
end

Parlora.close(session, :cancel)
