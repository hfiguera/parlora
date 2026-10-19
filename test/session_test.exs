defmodule Parlora.SessionTest do
  use ExUnit.Case, async: true
  alias Parlora.{AudioFrame, Event}
  alias Parlora.Session.Decisions

  alias Parlora.TestSupport.{
    FakeBackend,
    GrokCallsProvider,
    MemoryAudio,
    MemoryChannel,
    MemoryProvider,
    OrderPolicy
  }

  defp boot(options) do
    defaults = [
      channel: {MemoryChannel, observer: self()},
      provider: {MemoryProvider, observer: self()},
      backend: {FakeBackend, observer: self()},
      context_policy: {OrderPolicy, []},
      event_sink: self()
    ]

    # Most cases observe close within one second. Keep the fixture's deadline
    # inside that window while retaining explicit per-case shutdown limits.
    options =
      defaults
      |> Keyword.merge(options)
      |> Keyword.update(:limits, [shutdown_timeout_ms: 100], fn limits ->
        Keyword.put_new(limits, :shutdown_timeout_ms, 100)
      end)

    {:ok, pid} = Parlora.start_session(options)
    on_exit(fn -> if Process.alive?(pid), do: Parlora.close(pid) end)
    pid
  end

  defp session(options \\ []) do
    pid = boot(options)
    assert_receive {:adapter, :channel, channel}
    assert_receive {:adapter, :provider, provider}
    assert_receive {:adapter, :backend, backend}
    assert_receive {:parlora_event, %Event{source: :session, type: :ready}}
    {pid, channel, provider, backend}
  end

  defp transcript(provider, text, speaker \\ :user) do
    MemoryAudio.inject(provider, :transcript_delta, %{
      speaker: speaker,
      delta: text,
      start_ms: 0,
      end_ms: 100
    })
  end

  defp delegate(provider, id \\ "delegation-1") do
    MemoryAudio.inject(provider, :delegation_requested, %{id: id, offset_ms: 50, target: :client})
  end

  test "overflow recovery preserves the media connection and an in-flight backend action" do
    {pid, channel, provider, backend} = session()
    transcript(provider, "order 123")
    delegate(provider)
    assert_receive {:submitted, request}
    before = :sys.get_state(pid)
    MemoryAudio.inject(provider, :output_recovery_requested, %{token: 1, cause: :output_overflow})
    assert_receive {:output_recovery, 1, snapshot}
    assert snapshot.tasks[request.task_id].status == :submitted
    assert :sys.get_state(channel).epoch == 1
    assert Parlora.status(pid).output_recovery.token == 1
    assert :ok = FakeBackend.complete(backend, request, "Verified action completed once")
    assert_receive {:parlora_event, %Event{type: :request_completed}}
    refute_receive {:context, _}, 30
    refute_receive {:submitted, _}, 30
    assert :sys.get_state(pid).adapters == before.adapters
    assert :sys.get_state(pid).input_pipeline == before.input_pipeline
    assert :sys.get_state(pid).output_pipeline == before.output_pipeline
    assert Process.alive?(channel) and Process.alive?(backend)
    MemoryAudio.inject(provider, :output_recovered, %{token: 0})
    assert Parlora.status(pid).output_recovery.token == 1
    MemoryAudio.inject(provider, :output_recovered, %{token: 1})
    assert Parlora.status(pid).output_recovery.stage == :awaiting_user
    MemoryAudio.inject(provider, :output_recovered, %{token: 1})
    assert Parlora.status(pid).output_recovery.stage == :awaiting_user
    refute_receive {:context, _}, 30
    transcript(provider, " please continue")
    assert_receive {:context, %{content: "Verified action completed once"}}
    assert Parlora.status(pid).output_recovery == nil
    MemoryAudio.inject(provider, :output_recovered, %{token: 1})
    assert Parlora.status(pid).output_recovery == nil
    assert Parlora.status(pid).status == :ready
    FakeBackend.complete(backend, request, "Duplicate completion")
    refute_receive {:context, _}, 30
    refute_receive {:submitted, _}, 30
    refute_received {:parlora_event, %Event{source: :session, type: :closed}}
    refute_received {:parlora_event, %Event{source: :session, type: :ready}}
  end

  test "corrections remain authoritative through output recovery and suppression stays active" do
    {pid, channel, provider, backend} = session()
    transcript(provider, "order 123")
    delegate(provider)
    assert_receive {:submitted, first}
    transcript(provider, " actually order 124")
    assert_receive {:submitted, current}
    assert :ok = Parlora.control(pid, {:suppress_output, true})
    MemoryAudio.inject(provider, :output_recovery_requested, %{token: 1, cause: :output_overflow})
    assert_receive {:output_recovery, 1, _}
    FakeBackend.complete(backend, first, "Obsolete order 123")
    FakeBackend.complete(backend, current, "Current order 124")
    assert_receive {:parlora_event, %Event{type: :request_completed}}
    refute_receive {:context, _}, 30
    MemoryAudio.inject(provider, :output_recovered, %{token: 1})
    transcript(provider, " please continue")
    assert_receive {:parlora_event, %Event{type: :stale_result}}
    assert_receive {:context, %{content: "Current order 124", task_revision: 2}}
    assert :sys.get_state(channel).suppressed
    assert :sys.get_state(:sys.get_state(pid).output_pipeline).suppressed
    refute_receive {:submitted, _}, 30
    assert Parlora.status(pid).status == :ready
  end

  test "early delegation waits, duplicate delivery starts once, correction suppresses the old result" do
    {pid, _channel, provider, backend} = session()
    delegate(provider)
    refute_receive {:submitted, _request}, 30
    transcript(provider, "Look up order 123")
    assert_receive {:submitted, first}
    assert first.input == %{order: "123"}
    delegate(provider)
    transcript(provider, ". Actually order 124.")
    assert_receive {:submitted, second}
    assert second.task_id == first.task_id
    assert second.task_revision == 2
    assert second.id != first.id
    assert :ok = FakeBackend.complete(backend, first, "Wrong order result")
    assert_receive {:parlora_event, %Event{type: :stale_result}}
    refute_receive {:context, _update}, 30
    assert :ok = FakeBackend.complete(backend, second, "Order 124 arrives tomorrow")
    assert_receive {:context, update}
    assert update.task_revision == 2
    assert update.delegation_id == "delegation-1"
    FakeBackend.complete(backend, second, "Duplicate result")
    refute_receive {:context, _update}, 30
    assert map_size(Parlora.snapshot(pid).tasks) == 1
  end

  test "input and output continue while work is pending, without coordinator audio messages" do
    {_pid, channel, provider, _backend} = session()
    transcript(provider, "order 123")
    delegate(provider)
    assert_receive {:submitted, _request}
    frame = AudioFrame.pcm(:binary.copy(<<0, 0>>, 240), "microphone", 0)
    :ok = MemoryAudio.audio(channel, frame)
    :ok = MemoryAudio.audio(provider, %{frame | stream_id: "voice"})
    eventually(fn -> MemoryAudio.drain(provider) != [] end)
    eventually(fn -> MemoryAudio.drain(channel) != [] end)
  end

  for order <- [:old_first, :current_first] do
    @completion_order order
    test "a corrected Grok result keeps its shared route when completion order is #{order}" do
      {pid, _channel, provider, backend} =
        session(provider: {GrokCallsProvider, observer: self()})

      GrokCallsProvider.delegate(provider, "original-call")
      transcript(provider, "order 123")
      assert_receive {:submitted, first}
      transcript(provider, " actually order 124")
      assert_receive {:submitted, second}
      assert second.delegation_id == first.delegation_id
      assert second.task_revision == 2

      requests =
        if @completion_order == :old_first, do: [first, second], else: [second, first]

      for request <- requests do
        FakeBackend.complete(backend, request, "Order #{request.input.order} result")

        if request.id == first.id do
          assert_receive {:parlora_event, %Event{type: :stale_result}}
          refute GrokCallsProvider.records(provider)["original-call"].status == :superseded
        else
          assert_receive {:context, %{content: "Order 124 result", task_revision: 2}}
        end
      end

      eventually(fn -> Parlora.status(pid).jobs[second.id].delivery == :accepted end)
      assert GrokCallsProvider.records(provider)["original-call"].status == :completed
      FakeBackend.complete(backend, first, "Duplicate obsolete result")
      refute_receive {:context, _obsolete}, 30
      assert GrokCallsProvider.records(provider)["original-call"].status == :completed
    end
  end

  test "obsolete Grok work closes its route when the replacement has a distinct call" do
    {pid, _channel, provider, backend} =
      session(
        provider: {GrokCallsProvider, observer: self()},
        context_policy: {Parlora.TestSupport.ControlledPolicy, observer: self()}
      )

    GrokCallsProvider.delegate(provider, "old-call")
    assert_receive {:policy, worker, _snapshot, _trigger}

    send(
      worker,
      {:decisions,
       [
         %Parlora.ContextDecision{
           kind: :start_task,
           delegation_id: "old-call",
           input: %{order: "123"}
         }
       ]}
    )

    assert_receive {:submitted, first}
    GrokCallsProvider.delegate(provider, "new-call")
    assert_receive {:policy, worker, _snapshot, _trigger}

    send(
      worker,
      {:decisions,
       [
         %Parlora.ContextDecision{
           kind: :supersede_task,
           delegation_id: "new-call",
           task_id: first.task_id,
           expected_task_revision: 1,
           input: %{order: "124"}
         }
       ]}
    )

    assert_receive {:submitted, second}
    assert second.delegation_id == "new-call"
    FakeBackend.complete(backend, first, "Obsolete result")
    assert_receive {:parlora_event, %Event{type: :stale_result}}
    eventually(fn -> GrokCallsProvider.records(provider)["old-call"].status == :superseded end)
    assert GrokCallsProvider.records(provider)["new-call"].status == :pending
    FakeBackend.complete(backend, second, "Corrected result")
    assert_receive {:context, %{content: "Corrected result", delegation_id: "new-call"}}
    eventually(fn -> Parlora.status(pid).jobs[second.id].delivery == :accepted end)
  end

  test "a late Grok delegation associates with the correction without closing its original route" do
    {pid, _channel, provider, backend} =
      session(
        provider: {GrokCallsProvider, observer: self()},
        context_policy: {Parlora.TestSupport.ControlledPolicy, observer: self()}
      )

    GrokCallsProvider.delegate(provider, "original-call")
    assert_receive {:policy, worker, _snapshot, _trigger}

    send(
      worker,
      {:decisions,
       [
         %Parlora.ContextDecision{
           kind: :start_task,
           delegation_id: "original-call",
           input: %{order: "123"}
         }
       ]}
    )

    assert_receive {:submitted, first}
    transcript(provider, "actually order 124")
    assert_receive {:policy, worker, _snapshot, _trigger}

    send(
      worker,
      {:decisions,
       [
         %Parlora.ContextDecision{
           kind: :supersede_task,
           task_id: first.task_id,
           expected_task_revision: 1,
           input: %{order: "124"}
         }
       ]}
    )

    assert_receive {:submitted, second}
    FakeBackend.complete(backend, first, "Obsolete result")
    assert_receive {:parlora_event, %Event{type: :stale_result}}
    assert GrokCallsProvider.records(provider)["original-call"].status == :pending

    GrokCallsProvider.delegate(provider, "late-call")
    assert_receive {:policy, worker, _snapshot, _trigger}

    send(
      worker,
      {:decisions,
       [
         %Parlora.ContextDecision{
           kind: :associate_delegation,
           delegation_id: "late-call",
           task_id: first.task_id,
           expected_task_revision: 2
         }
       ]}
    )

    assert_receive {:parlora_event, %Event{type: :delegation_associated}}
    eventually(fn -> GrokCallsProvider.records(provider)["late-call"].status == :completed end)
    assert GrokCallsProvider.records(provider)["original-call"].status == :pending
    FakeBackend.complete(backend, second, "Corrected result")
    assert_receive {:context, %{content: "Corrected result", delegation_id: "original-call"}}
    eventually(fn -> Parlora.status(pid).jobs[second.id].delivery == :accepted end)
  end

  test "uncertainty is spoken once without claiming completion, and a later verified result still arrives" do
    {pid, _channel, provider, backend} = session()
    transcript(provider, "order 124")
    delegate(provider)
    assert_receive {:submitted, request}

    for _ <- 1..2,
        do:
          FakeBackend.inject(backend, :request_uncertain, %{reason: :framework_failure},
            request_id: request.id
          )

    assert_receive {:context, notice}
    assert notice.kind == :speakable
    assert notice.task_id == request.task_id and notice.task_revision == 1
    assert notice.delegation_id == request.delegation_id
    assert notice.content =~ "No verified result"
    assert notice.content =~ "Do not retry automatically"
    refute_receive {:context, _duplicate}, 30
    assert Parlora.status(pid).jobs[request.id].status == :uncertain
    assert Parlora.status(pid).jobs[request.id].uncertainty_reason == :framework_failure
    assert Parlora.snapshot(pid).tasks[request.task_id].status == :uncertain

    MemoryAudio.inject(provider, :context_acknowledged, %{}, command_id: notice.id)
    assert Parlora.status(pid).jobs[request.id].uncertainty_delivery == :accepted
    FakeBackend.complete(backend, request, "Verified order 124 status")
    assert_receive {:context, %{content: "Verified order 124 status"}}
    assert Parlora.status(pid).jobs[request.id].status == :completed
  end

  test "uncertainty waits for correction interpretation and obsolete notices are suppressed" do
    {pid, _channel, provider, backend} =
      session(context_policy: {Parlora.TestSupport.ControlledPolicy, observer: self()})

    delegate(provider)
    assert_receive {:policy, worker, _snapshot, _trigger}

    send(
      worker,
      {:decisions,
       [
         %Parlora.ContextDecision{
           kind: :start_task,
           delegation_id: "delegation-1",
           input: %{order: "123"}
         }
       ]}
    )

    assert_receive {:submitted, first}
    transcript(provider, "Actually order 124")
    assert_receive {:policy, correcting, _snapshot, _trigger}

    FakeBackend.inject(backend, :request_uncertain, %{reason: "private raw error"},
      request_id: first.id
    )

    refute_receive {:context, _notice}, 30
    send(correcting, {:decisions, []})
    assert_receive {:policy, rechecking, _snapshot, _trigger}

    send(
      rechecking,
      {:decisions,
       [
         %Parlora.ContextDecision{
           kind: :supersede_task,
           task_id: first.task_id,
           expected_task_revision: 1,
           input: %{order: "124"}
         }
       ]}
    )

    assert_receive {:submitted, second}
    assert Parlora.status(pid).jobs[first.id].uncertainty_delivery == :stale
    assert Parlora.status(pid).jobs[first.id].uncertainty_reason == :unknown
    refute_receive {:context, _notice}, 30
    FakeBackend.complete(backend, second, "Current verified result")
    assert_receive {:context, %{content: "Current verified result"}}
  end

  test "a current job deadline reports uncertainty without claiming that work stopped" do
    {pid, _channel, provider, backend} = session(limits: [job_timeout_ms: 100])
    transcript(provider, "order 124")
    delegate(provider)
    assert_receive {:submitted, request}
    assert_receive {:context, notice}
    assert notice.content =~ "Do not promise the work is still running"
    assert notice.content =~ "Do not claim any external action completed"
    assert Parlora.status(pid).jobs[request.id].uncertainty_reason == :job_deadline
    FakeBackend.complete(backend, request, "Late verified result")
    assert_receive {:context, %{content: "Late verified result"}}
  end

  test "a correction atomically claims its new delegation and delivers through it once" do
    {pid, _channel, provider, backend} =
      session(context_policy: {Parlora.TestSupport.ControlledPolicy, observer: self()})

    delegate(provider, "original")
    assert_receive {:policy, worker, _snapshot, _trigger}

    send(
      worker,
      {:decisions,
       [
         %Parlora.ContextDecision{
           kind: :start_task,
           delegation_id: "original",
           input: %{order: "123"}
         }
       ]}
    )

    assert_receive {:submitted, first}
    FakeBackend.complete(backend, first, "Order 123 is shipped")
    assert_receive {:context, %{delegation_id: "original"}}
    delegate(provider, "correction")
    assert_receive {:policy, worker, _snapshot, _trigger}

    correction = %Parlora.ContextDecision{
      kind: :supersede_task,
      task_id: first.task_id,
      expected_task_revision: 1,
      delegation_id: "correction",
      input: %{order: "124"}
    }

    state = :sys.get_state(pid)

    for invalid <- [
          %{correction | delegation_id: "missing"},
          %{correction | delegation_id: "original"},
          %{correction | expected_task_revision: 2}
        ] do
      assert {:error, %{code: :invalid_argument}} =
               Decisions.apply_batch(state, [invalid])
    end

    assert {:error, %{code: :invalid_argument}} =
             Decisions.apply_batch(state, [
               correction,
               %Parlora.ContextDecision{
                 kind: :start_task,
                 delegation_id: "correction",
                 input: %{order: "124"}
               }
             ])

    send(worker, {:decisions, [correction]})
    assert_receive {:submitted, second}
    assert second.delegation_id == "correction"
    assert second.task_revision == 2
    FakeBackend.complete(backend, second, "Order 124 is out for delivery")
    assert_receive {:context, %{delegation_id: "correction", task_revision: 2}}
    assert Parlora.status(pid).delegations["correction"].status == :claimed
    refute_receive {:context, _duplicate}, 30
  end

  test "unrelated and late transcript fragments preserve text without revising the job" do
    {pid, _channel, provider, _backend} = session()
    transcript(provider, "order 123")
    delegate(provider)
    assert_receive {:submitted, request}
    transcript(provider, " yes yes ")
    transcript(provider, "Working on it", :assistant)
    eventually(fn -> Enum.count_until(Parlora.snapshot(pid).transcripts, 4) == 3 end)
    snapshot = Parlora.snapshot(pid)
    assert snapshot.tasks[request.task_id].revision == 1

    assert Enum.map(snapshot.transcripts, & &1.delta) == [
             "Working on it",
             " yes yes ",
             "order 123"
           ]

    refute_receive {:submitted, _request}, 30
  end

  test "superseded work occupies capacity until completion while replacement waits" do
    {pid, _channel, provider, backend} =
      session(provider: {GrokCallsProvider, observer: self()}, limits: [max_jobs: 1])

    transcript(provider, "order 123")
    GrokCallsProvider.delegate(provider, "delegation-1")
    assert_receive {:submitted, first}
    transcript(provider, " actually order 124")
    assert_receive {:parlora_event, %Event{type: :task_queued}}
    refute_receive {:submitted, _request}, 30
    FakeBackend.complete(backend, first, "Stale result")
    assert_receive {:parlora_event, %Event{type: :stale_result}}
    assert_receive {:submitted, second}
    assert second.task_revision == 2
    assert GrokCallsProvider.records(provider)["delegation-1"].status == :pending
    refute_receive {:context, _update}, 30
    FakeBackend.complete(backend, second, "Corrected queued result")
    assert_receive {:context, %{content: "Corrected queued result"}}
    eventually(fn -> Parlora.status(pid).jobs[second.id].delivery == :accepted end)
  end

  test "missing provider finalization is observable and session resources stop" do
    {pid, channel, _provider, backend} =
      session(
        provider: {MemoryProvider, observer: self(), no_close_event: true},
        limits: [shutdown_timeout_ms: 40]
      )

    ref = Process.monitor(pid)
    assert :ok = Parlora.close(pid)

    assert_receive {:parlora_event,
                    %Event{source: :session, type: :closed, payload: %{finalized?: false}}}

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    eventually(fn -> not Process.alive?(channel) and not Process.alive?(backend) end)
  end

  test "fresh context seeds no automatic backend replay" do
    {pid, _channel, _provider, _backend} =
      session(context: %{verified_order: "124", status: :completed})

    assert Parlora.snapshot(pid).application_context.status == :completed
    assert Parlora.snapshot(pid).tasks == %{}
    refute_receive {:submitted, _request}, 30
  end

  test "stale context decisions are discarded and reevaluated against current context" do
    {pid, _channel, provider, _backend} =
      session(context_policy: {Parlora.TestSupport.ControlledPolicy, observer: self()})

    delegate(provider)
    assert_receive {:policy, old_worker, old, _trigger}
    assert :ok = Parlora.update_context(pid, %{order: "124"})

    decision = %Parlora.ContextDecision{
      kind: :start_task,
      delegation_id: "delegation-1",
      input: %{order: "123"}
    }

    send(old_worker, {:decisions, [decision]})
    assert_receive {:policy, new_worker, current, _trigger}
    assert current.revision > old.revision
    refute_receive {:submitted, _request}, 30
    send(new_worker, {:decisions, [%{decision | input: %{order: "124"}}]})
    assert_receive {:submitted, request}
    assert request.input.order == "124"
  end

  test "clarification is deduplicated while the delegation remains pending" do
    {_pid, _channel, provider, _backend} =
      session(context_policy: {Parlora.TestSupport.ControlledPolicy, observer: self()})

    delegate(provider)
    assert_receive {:policy, worker, _snapshot, _trigger}

    decision = %Parlora.ContextDecision{
      kind: :request_clarification,
      delegation_id: "delegation-1",
      message: "Which order?"
    }

    send(worker, {:decisions, [decision]})
    assert_receive {:context, %{content: "Which order?"}}
    transcript(provider, " hmm ")
    assert_receive {:policy, next_worker, _snapshot, _trigger}
    send(next_worker, {:decisions, [decision]})
    refute_receive {:context, _update}, 30
    refute_receive {:submitted, _request}, 30
  end

  test "speech transitions and new caller input invalidate an outstanding clarification judgment" do
    {pid, channel, provider, _backend} =
      session(context_policy: {Parlora.TestSupport.ControlledPolicy, observer: self()})

    MemoryAudio.inject(provider, :provider_speech, %{state: :idle})
    delegate(provider)
    assert_receive {:policy, old_worker, old, _}
    assert old.provider_speech == :idle
    MemoryAudio.inject(provider, :provider_speech, %{state: :speaking})
    eventually(fn -> Parlora.snapshot(pid).revision > old.revision end)
    transcript(provider, "Actually order 124")
    eventually(fn -> Parlora.snapshot(pid).revision > old.revision end)
    frame = AudioFrame.pcm(:binary.copy(<<0, 0>>, 240), "voice", 0)
    :ok = MemoryAudio.audio(provider, frame)
    eventually(fn -> MemoryAudio.drain(channel) != [] end)

    decision = %Parlora.ContextDecision{
      kind: :request_clarification,
      delegation_id: "delegation-1",
      message: "Obsolete question"
    }

    send(old_worker, {:decisions, [decision]})
    assert_receive {:policy, current_worker, current, _}
    assert current.provider_speech == :speaking
    assert current.revision > old.revision
    refute_receive {:context, _}, 30
    send(current_worker, {:decisions, []})
  end

  test "delegation waits and questions remain unresolved until the delegation is claimed" do
    {pid, _channel, provider, _backend} =
      session(context_policy: {Parlora.TestSupport.ControlledPolicy, observer: self()})

    delegate(provider)
    assert_receive {:policy, worker, _snapshot, _trigger}
    assert Parlora.status(pid).interpretation == :running

    wait = %Parlora.ContextDecision{kind: :wait_for_context, delegation_id: "delegation-1"}
    send(worker, {:decisions, [wait]})
    eventually(fn -> Parlora.status(pid).interpretation == :unresolved end)

    transcript(provider, "I forgot")
    assert_receive {:policy, worker, _snapshot, _trigger}
    question = %{wait | kind: :request_clarification, message: "Which order?"}
    send(worker, {:decisions, [question]})
    assert_receive {:context, %{content: "Which order?"}}
    eventually(fn -> Parlora.status(pid).interpretation == :unresolved end)

    # A subsequent empty batch must not hide the still-pending question.
    transcript(provider, " ", :assistant)
    assert_receive {:policy, worker, _snapshot, _trigger}
    send(worker, {:decisions, []})
    eventually(fn -> Parlora.status(pid).interpretation == :unresolved end)

    transcript(provider, "124")
    assert_receive {:policy, worker, _snapshot, _trigger}
    send(worker, {:decisions, [%{wait | kind: :start_task, input: %{order: "124"}}]})
    assert_receive {:submitted, _request}
    eventually(fn -> Parlora.status(pid).interpretation == :settled end)
    assert Parlora.status(pid).delegations["delegation-1"].status == :claimed
  end

  test "clarification keys allow a new question while suppressing old attempts" do
    {_pid, _channel, provider, _backend} =
      session(context_policy: {Parlora.TestSupport.ControlledPolicy, observer: self()})

    delegate(provider)

    decision = %Parlora.ContextDecision{
      kind: :request_clarification,
      delegation_id: "delegation-1",
      message: "Which order?",
      clarification_key: "first-reply"
    }

    assert_receive {:policy, worker, _snapshot, _trigger}
    send(worker, {:decisions, [decision]})
    assert_receive {:context, first}
    transcript(provider, " I forgot ")
    assert_receive {:policy, worker, _snapshot, _trigger}
    send(worker, {:decisions, [%{decision | clarification_key: "second-reply"}]})
    assert_receive {:context, second}
    refute first.id == second.id
    transcript(provider, " hmm ")
    assert_receive {:policy, worker, _snapshot, _trigger}
    send(worker, {:decisions, [decision]})
    refute_receive {:context, _update}, 30
  end

  test "unconfirmed cancellation does not release a running job or imply success" do
    {pid, _channel, provider, backend} =
      session(limits: [max_jobs: 1, cancellation_timeout_ms: 30])

    transcript(provider, "order 123")
    delegate(provider)
    assert_receive {:submitted, first}
    assert :ok = Parlora.cancel(pid, first.id, :requested, "cancel-1")
    assert :ok = Parlora.cancel(pid, first.id, :requested, "cancel-1")
    assert_receive {:parlora_event, %Event{type: :cancellation_requested}}

    assert_receive {:parlora_event,
                    %Event{type: :cancellation_unconfirmed, command_id: "cancel-1"}}

    transcript(provider, " actually order 124")
    assert_receive {:parlora_event, %Event{type: :task_queued}}
    refute_receive {:submitted, _request}, 30
    FakeBackend.complete(backend, first, "Late completion after advisory cancel")
    assert_receive {:parlora_event, %Event{type: :stale_result}}
    assert_receive {:submitted, second}
    assert second.input.order == "124"
  end

  test "playback clear command reuse preserves the epoch and independent mute leaves jobs running" do
    {pid, channel, provider, _backend} = session()
    transcript(provider, "order 123")
    delegate(provider)
    assert_receive {:submitted, _request}
    assert :ok = Parlora.control(pid, {:clear_output, :next}, "clear-1")
    assert :ok = Parlora.control(pid, {:clear_output, :next}, "clear-1")
    assert :ok = Parlora.control(pid, {:input_muted, true}, "mute-1")
    frame = AudioFrame.pcm(:binary.copy(<<1, 0>>, 240), "voice", 0)
    :ok = MemoryAudio.audio(provider, frame)
    eventually(fn -> MemoryAudio.drain(channel) != [] end)
    refute_receive {:parlora_event, %Event{type: :cancellation_requested}}, 30
  end

  test "cumulative usage snapshots are not summed" do
    {pid, _channel, provider, _backend} = session()
    MemoryAudio.inject(provider, :usage_updated, %{seconds: 4, final?: false})
    MemoryAudio.inject(provider, :usage_updated, %{seconds: 7, final?: false})
    assert :ok = Parlora.close(pid)

    assert_receive {:parlora_event,
                    %Event{source: :session, type: :closed, payload: %{usage: %{seconds: 7}}}}
  end

  test "full correction queue closes before an obsolete answer can be delivered" do
    {pid, _channel, provider, backend} = session(limits: [max_jobs: 1, max_pending_jobs: 1])
    ref = Process.monitor(pid)
    transcript(provider, "order 123")
    delegate(provider)
    assert_receive {:submitted, first}
    transcript(provider, " actually order 124")
    assert_receive {:parlora_event, %Event{type: :task_queued}}
    transcript(provider, " actually order 125")

    assert_receive {:parlora_event,
                    %Event{type: :policy_rejected, payload: %{error: %{code: :backpressure}}}}

    if Process.alive?(backend), do: FakeBackend.complete(backend, first, "Old answer")
    refute_receive {:context, _update}, 30
    assert_receive {:parlora_event, %Event{source: :session, type: :closed}}
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end

  test "queued cancellation is confirmed locally and repeated IDs stay idempotent" do
    {pid, _channel, provider, backend} = session(limits: [max_jobs: 1])
    transcript(provider, "order 123")
    delegate(provider)
    assert_receive {:submitted, first}
    transcript(provider, " actually order 124")
    assert_receive {:parlora_event, %Event{type: :task_queued, request_id: queued_id}}
    assert :ok = Parlora.cancel(pid, queued_id, :test, "cancel-queued")
    assert :ok = Parlora.cancel(pid, queued_id, :test, "cancel-queued")

    assert_receive {:parlora_event,
                    %Event{
                      type: :request_cancelled,
                      payload: %{metadata: %{execution: :never_submitted}}
                    }}

    FakeBackend.complete(backend, first, "Old result")
    refute_receive {:submitted, _request}, 30
  end

  test "stale queued revisions do not strand the latest replacement" do
    {_pid, _channel, provider, backend} = session(limits: [max_jobs: 1])
    transcript(provider, "order 123")
    delegate(provider)
    assert_receive {:submitted, first}

    for number <- ["124", "125"] do
      transcript(provider, " actually order " <> number)
      assert_receive {:parlora_event, %Event{type: :task_queued}}
    end

    FakeBackend.complete(backend, first, "Old result")
    assert_receive {:submitted, current}
    assert current.input.order == "125"
  end

  test "audio pipeline death closes the owned session" do
    {pid, _channel, _provider, _backend} = session()
    pipeline = :sys.get_state(pid).input_pipeline
    Process.exit(pipeline, :kill)

    assert_receive {:parlora_event,
                    %Event{type: :adapter_down, payload: %{role: :input_pipeline}}}

    assert_receive {:parlora_event, %Event{source: :session, type: :closed}}
  end

  test "readiness gates controls and audio until all adapters are ready" do
    pid = boot(provider: {MemoryProvider, observer: self(), delay_ready: true})
    assert_receive {:adapter, :provider, provider}
    assert {:error, %{code: :not_ready}} = Parlora.control(pid, {:input_muted, true})
    refute_receive {:parlora_event, %Event{source: :session, type: :ready}}, 30
    send(provider, :ready)
    assert_receive {:parlora_event, %Event{source: :session, type: :ready}}
  end

  test "incompatible capabilities fail startup and close partial ownership" do
    pid =
      boot(
        provider:
          {MemoryProvider, observer: self(), capabilities: %Parlora.Provider.Capabilities{}}
      )

    assert_receive {:parlora_event,
                    %Event{
                      source: :session,
                      type: :failed,
                      payload: %{error: %{code: :unsupported}}
                    }}

    assert_receive {:parlora_event, %Event{source: :session, type: :closed}}
    eventually(fn -> not Process.alive?(pid) end)
  end

  test "provider configuration failure cleans the already-started channel" do
    pid = boot(provider: {Parlora.Providers.OpenAI, []})
    assert_receive {:adapter, :channel, channel}
    assert_receive {:parlora_event, %Event{source: :session, type: :failed}}
    assert_receive {:parlora_event, %Event{source: :session, type: :closed}}
    eventually(fn -> not Process.alive?(pid) and not Process.alive?(channel) end)
  end

  test "an append rejection remains observable without repeating it" do
    {_pid, _channel, provider, backend} =
      session(provider: {MemoryProvider, observer: self(), reject_context: true})

    transcript(provider, "order 123")
    delegate(provider)
    assert_receive {:submitted, request}
    FakeBackend.complete(backend, request, "Rejected summary")
    assert_receive {:context, update}
    assert_receive {:parlora_event, %Event{type: :context_rejected, command_id: id}}
    assert id == update.id
    refute_receive {:context, _update}, 30
  end

  test "backend clarification reaches the policy with its revision and facts" do
    {_pid, _channel, provider, backend} =
      session(context_policy: {Parlora.TestSupport.ControlledPolicy, observer: self()})

    delegate(provider)
    assert_receive {:policy, worker, _snapshot, _trigger}

    send(
      worker,
      {:decisions,
       [
         %Parlora.ContextDecision{
           kind: :start_task,
           delegation_id: "delegation-1",
           input: %{order: "123"}
         }
       ]}
    )

    assert_receive {:submitted, request}

    FakeBackend.inject(
      backend,
      :request_clarification,
      %{task_revision: 1, question: "Which location?"},
      request_id: request.id
    )

    assert_receive {:policy, worker, snapshot, %{kind: :backend_clarification, request_id: id}}
    assert id == request.id
    assert snapshot.tasks[request.task_id].clarification.question == "Which location?"
    send(worker, {:decisions, []})
  end

  test "supported updates correlate acknowledgment and reject the prior revision" do
    caps = %Parlora.Backend.Capabilities{updates?: true, cancellation: :advisory}

    {pid, _channel, provider, backend} =
      session(
        backend: {FakeBackend, observer: self(), capabilities: caps},
        context_policy: {Parlora.TestSupport.ControlledPolicy, observer: self()}
      )

    delegate(provider)
    assert_receive {:policy, worker, _snapshot, _trigger}

    send(
      worker,
      {:decisions,
       [
         %Parlora.ContextDecision{
           kind: :start_task,
           delegation_id: "delegation-1",
           input: %{order: "123"}
         }
       ]}
    )

    assert_receive {:submitted, first}
    Parlora.update_context(pid, %{order: "124"})
    assert_receive {:policy, worker, _snapshot, _trigger}

    send(
      worker,
      {:decisions,
       [
         %Parlora.ContextDecision{
           kind: :update_task,
           task_id: first.task_id,
           expected_task_revision: 1,
           input: %{order: "124"}
         }
       ]}
    )

    assert_receive {:updated, command, replacement}
    assert replacement.id == first.id
    assert replacement.task_revision == 2

    FakeBackend.inject(backend, :update_applied, %{task_revision: 2},
      request_id: first.id,
      command_id: command
    )

    FakeBackend.complete(backend, first, "Old revision")
    refute_receive {:context, _update}, 30
    FakeBackend.complete(backend, replacement, "Current revision")
    assert_receive {:context, %{content: "Current revision", task_revision: 2}}
  end

  test "explicit backend cancellation produces a terminal outcome without a spoken success" do
    {pid, _channel, provider, backend} = session()
    transcript(provider, "order 123")
    delegate(provider)
    assert_receive {:submitted, request}
    assert :ok = Parlora.cancel(pid, request.id, :test)
    FakeBackend.complete(backend, request, nil, :cancelled)
    assert_receive {:parlora_event, %Event{source: :backend, type: :request_cancelled}}
    eventually(fn -> Parlora.snapshot(pid).tasks[request.task_id].status == :cancelled end)
    refute_receive {:context, _update}, 30
  end

  test "a permanently blocked audio consumer closes instead of replaying arbitrarily old audio" do
    {_pid, _channel, provider, _backend} =
      session(limits: [audio_queue_bytes: 960, audio_backpressure_timeout_ms: 30])

    for index <- 1..2 do
      :ok =
        MemoryAudio.audio(provider, AudioFrame.pcm(:binary.copy(<<0, 0>>, 480), "voice", index))

      Process.sleep(30)
    end

    assert_receive {:parlora_event,
                    %Event{type: :audio_discontinuity, payload: %{cause: :timeout}}}

    assert_receive {:parlora_event, %Event{source: :session, type: :closed}}
  end

  test "session death also terminates a blocked context-policy worker" do
    {pid, _channel, provider, _backend} =
      session(context_policy: {Parlora.TestSupport.ControlledPolicy, observer: self()})

    delegate(provider)
    assert_receive {:policy, worker, _snapshot, _trigger}
    ref = Process.monitor(worker)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker, _reason}
  end

  test "job deadlines distinguish unconfirmed running work from unsubmitted expiry" do
    {_pid, _channel, provider, backend} = session(limits: [max_jobs: 1, job_timeout_ms: 50])
    transcript(provider, "order 123")
    delegate(provider)
    assert_receive {:submitted, first}
    transcript(provider, " actually order 124")
    assert_receive {:parlora_event, %Event{type: :task_queued, request_id: queued}}

    assert_receive {:parlora_event,
                    %Event{source: :session, type: :request_uncertain, request_id: running}}

    assert running == first.id

    assert_receive {:parlora_event,
                    %Event{source: :session, type: :request_failed, request_id: ^queued}}

    FakeBackend.complete(backend, first, "Late old outcome")
    refute_receive {:submitted, _request}, 30
    refute_receive {:context, _update}, 30
  end

  test "startup options do not appear in supervisor diagnostic MFA arguments or context" do
    {pid, _channel, _provider, _backend} =
      session(provider: {MemoryProvider, observer: self(), api_key: "test-secret-marker"})

    state = :sys.get_state(pid)
    {:dictionary, dictionary} = Process.info(pid, :dictionary)
    [session_supervisor | _ancestors] = Keyword.fetch!(dictionary, :"$ancestors")
    adapter_supervisor = GenServer.whereis(Parlora.SessionSupervisor.via(state.id, :adapters))

    for supervisor <- [Parlora.Sessions, session_supervisor, adapter_supervisor] do
      refute inspect(:sys.get_state(supervisor), limit: :infinity) =~ "test-secret-marker"
      refute inspect(:sys.get_status(supervisor), limit: :infinity) =~ "test-secret-marker"
    end

    assert {:ok, spec} = :supervisor.get_childspec(session_supervisor, Parlora.Session)
    assert spec.restart == :temporary
    assert spec.significant
    assert spec.modules == [Parlora.Session]
    refute inspect(spec, limit: :infinity) =~ "test-secret-marker"
    refute inspect(Parlora.snapshot(pid), limit: :infinity) =~ "test-secret-marker"
  end

  test "a slow event subscriber is detached while the session keeps running" do
    {pid, _channel, provider, _backend} = session(limits: [max_subscriber_queue: 100])

    subscriber =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> send(subscriber, :stop) end)
    assert :ok = Parlora.subscribe(pid, subscriber)
    for _message <- 1..100, do: send(subscriber, :unrelated)
    MemoryAudio.inject(provider, :usage_updated, %{seconds: 1})

    eventually(fn ->
      Process.info(subscriber, :message_queue_len) == {:message_queue_len, 101}
    end)

    MemoryAudio.inject(provider, :usage_updated, %{seconds: 2})
    assert Process.info(subscriber, :message_queue_len) == {:message_queue_len, 101}
    assert Process.alive?(pid)
  end

  test "completion waits for an in-flight correction policy before becoming speakable" do
    {_pid, _channel, provider, backend} =
      session(context_policy: {Parlora.TestSupport.ControlledPolicy, observer: self()})

    delegate(provider)
    assert_receive {:policy, worker, _snapshot, _trigger}

    send(
      worker,
      {:decisions,
       [
         %Parlora.ContextDecision{
           kind: :start_task,
           delegation_id: "delegation-1",
           input: %{order: "123"}
         }
       ]}
    )

    assert_receive {:submitted, first}
    transcript(provider, "Actually order 124")
    assert_receive {:policy, correcting, _snapshot, _trigger}
    FakeBackend.complete(backend, first, "Old answer arriving during interpretation")
    refute_receive {:context, _update}, 30

    send(
      correcting,
      {:decisions,
       [
         %Parlora.ContextDecision{
           kind: :supersede_task,
           task_id: first.task_id,
           expected_task_revision: 1,
           input: %{order: "124"}
         }
       ]}
    )

    assert_receive {:submitted, second}
    assert_receive {:parlora_event, %Event{type: :stale_result}}
    FakeBackend.complete(backend, second, "Current answer")
    assert_receive {:context, %{content: "Current answer"}}
  end

  test "status distinguishes execution, result admission, provider acceptance, and audio evidence" do
    {pid, channel, provider, backend} =
      session(provider: {MemoryProvider, observer: self(), delay_context_ack: true})

    delegate(provider)
    assert_receive {:parlora_event, %Event{type: :delegation_pending}}
    assert Parlora.status(pid).delegations["delegation-1"].status == :pending
    transcript(provider, "order 123")
    assert_receive {:submitted, request}
    assert_receive {:parlora_event, %Event{type: :request_started}}
    running = Parlora.status(pid).jobs[request.id]
    assert running.status == :submitted
    assert is_integer(running.started_at_us)
    refute Map.has_key?(running, :input)

    FakeBackend.complete(backend, request, "Private result contents")
    assert_receive {:context, update}

    assert_receive {:parlora_event,
                    %Event{type: :result_delivery, payload: %{stage: :awaiting_provider}}}

    status = Parlora.status(pid)
    assert status.jobs[request.id].status == :completed
    assert status.jobs[request.id].delivery == :awaiting_provider
    assert status.jobs[request.id].result_command_id == update.id
    assert status.playback == %{}
    refute inspect(status) =~ "Private result contents"
    refute inspect(status) =~ "order 123"

    MemoryAudio.inject(provider, :context_acknowledged, %{}, command_id: "unrelated")
    assert Parlora.status(pid).jobs[request.id].delivery == :awaiting_provider
    MemoryAudio.inject(provider, :context_acknowledged, %{}, command_id: update.id)

    assert_receive {:parlora_event,
                    %Event{type: :result_delivery, request_id: id, payload: %{stage: :accepted}}}

    assert id == request.id
    assert Parlora.status(pid).playback == %{}

    MemoryAudio.inject(channel, :playback_observed, %{
      stage: :queued,
      evidence: :queue,
      epoch: 0,
      sequence: 1,
      stream_id: "voice"
    })

    MemoryAudio.inject(channel, :playback_observed, %{
      stage: :handed_off,
      evidence: :handoff,
      epoch: 0,
      first_sample: 0,
      end_sample: 240
    })

    eventually(fn -> Map.has_key?(Parlora.status(pid).playback, :handed_off) end)
    status = Parlora.status(pid)
    assert status.jobs[request.id].delivery == :accepted
    assert status.playback.queued.evidence == :queue
    assert status.playback.handed_off.end_sample == 240
    refute Map.has_key?(status.playback.handed_off, :request_id)
  end

  test "rejected and unacknowledged results remain distinct without retries" do
    for {payload, expected} <- [{%{}, :rejected}, {%{outcome: :unknown}, :unknown}] do
      {pid, _channel, provider, backend} =
        session(provider: {MemoryProvider, observer: self(), delay_context_ack: true})

      transcript(provider, "order 123")
      delegate(provider)
      assert_receive {:submitted, request}
      FakeBackend.complete(backend, request, "Result")
      assert_receive {:context, update}
      MemoryAudio.inject(provider, :context_rejected, payload, command_id: update.id)
      eventually(fn -> Parlora.status(pid).jobs[request.id].delivery == expected end)
      refute_receive {:context, _retry}, 30
    end
  end

  test "delegation association rejects stale revisions and simultaneous task revision" do
    {pid, _channel, provider, _backend} =
      session(context_policy: {Parlora.TestSupport.ControlledPolicy, observer: self()})

    delegate(provider)
    assert_receive {:policy, worker, _snapshot, _trigger}

    send(
      worker,
      {:decisions,
       [
         %Parlora.ContextDecision{
           kind: :start_task,
           delegation_id: "delegation-1",
           input: %{order: "123"}
         }
       ]}
    )

    assert_receive {:submitted, request}
    delegate(provider, "late")
    assert_receive {:policy, worker, _snapshot, _trigger}

    association = %Parlora.ContextDecision{
      kind: :associate_delegation,
      delegation_id: "late",
      task_id: request.task_id,
      expected_task_revision: 2
    }

    send(worker, {:decisions, [association]})
    assert_receive {:parlora_event, %Event{type: :policy_rejected}}
    assert Parlora.status(pid).delegations["late"].status == :pending

    transcript(provider, " actually order 124")
    assert_receive {:policy, worker, _snapshot, _trigger}

    supersede = %Parlora.ContextDecision{
      kind: :supersede_task,
      task_id: request.task_id,
      expected_task_revision: 1,
      input: %{order: "124"}
    }

    send(worker, {:decisions, [%{association | expected_task_revision: 1}, supersede]})
    assert_receive {:parlora_event, %Event{type: :policy_rejected}}
    assert Parlora.status(pid).delegations["late"].status == :pending
    refute_receive {:submitted, _extra}, 30
  end

  test "follow-up admission validates its anchor and preserves nullable delegation identity" do
    {pid, _channel, provider, backend} =
      session(context_policy: {Parlora.TestSupport.ControlledPolicy, observer: self()})

    delegate(provider)
    assert_receive {:policy, worker, _snapshot, _trigger}

    send(
      worker,
      {:decisions,
       [
         %Parlora.ContextDecision{
           kind: :start_task,
           delegation_id: "delegation-1",
           input: %{operation: :status}
         }
       ]}
    )

    assert_receive {:submitted, first}

    followup = %Parlora.ContextDecision{
      kind: :start_task,
      anchor_task_id: first.task_id,
      expected_anchor_revision: 1,
      input: %{operation: :items}
    }

    for invalid <- [
          %{followup | expected_anchor_revision: 2},
          %{followup | anchor_task_id: "missing"},
          %{followup | delegation_id: "delegation-1"},
          %{followup | anchor_task_id: nil},
          %{followup | expected_anchor_revision: nil},
          %{followup | expected_anchor_revision: 0},
          %{followup | task_id: first.task_id},
          %{followup | expected_task_revision: 1},
          %{followup | kind: :no_action},
          %{followup | kind: :supersede_task, task_id: first.task_id, expected_task_revision: 1},
          %Parlora.ContextDecision{
            kind: :start_task,
            task_id: first.task_id,
            expected_task_revision: 1,
            input: %{}
          }
        ] do
      transcript(provider, " more context")
      assert_receive {:policy, worker, _snapshot, _trigger}
      send(worker, {:decisions, [invalid]})
      assert_receive {:parlora_event, %Event{type: :policy_rejected}}
      refute_receive {:submitted, _}, 20
    end

    # Anchor reads preserve the existing per-task batch conflict rule: neither
    # two starts from one anchor nor revising that anchor can apply together.
    for batch <- [
          [followup, followup],
          [
            followup,
            %Parlora.ContextDecision{
              kind: :supersede_task,
              task_id: first.task_id,
              expected_task_revision: 1,
              input: %{operation: :tracking}
            }
          ]
        ] do
      transcript(provider, " more context")
      assert_receive {:policy, worker, _snapshot, _trigger}
      send(worker, {:decisions, batch})
      assert_receive {:parlora_event, %Event{type: :policy_rejected}}
      refute_receive {:submitted, _}, 20
      assert map_size(Parlora.snapshot(pid).tasks) == 1
    end

    anchor_before = Parlora.snapshot(pid).tasks[first.task_id]
    transcript(provider, " list the items")
    assert_receive {:policy, worker, _snapshot, _trigger}
    send(worker, {:decisions, [followup]})
    assert_receive {:submitted, second}
    refute second.task_id == first.task_id
    refute second.id == first.id
    assert second.task_revision == 1
    assert second.delegation_id == nil
    assert Parlora.snapshot(pid).tasks[first.task_id] == anchor_before
    assert map_size(Parlora.snapshot(pid).tasks) == 2
    assert map_size(Parlora.status(pid).delegations) == 1
    :ok = FakeBackend.complete(backend, second, "One desk lamp")
    assert_receive {:context, update}
    assert update.delegation_id == nil
  end

  test "startup discards buffered pre-ready capture and forwards fresh input" do
    pid = boot(provider: {MemoryProvider, observer: self(), delay_ready: true})
    assert_receive {:adapter, :channel, channel}
    assert_receive {:adapter, :provider, provider}
    assert_receive {:adapter, :backend, _backend}
    old = AudioFrame.pcm(:binary.copy(<<1, 0>>, 240), "old", 0)
    :ok = MemoryAudio.audio(channel, old)
    send(provider, :ready)
    assert_receive {:parlora_event, %Event{source: :session, type: :ready}}

    assert_receive {:parlora_event,
                    %Event{
                      type: :audio_discontinuity,
                      payload: %{cause: :startup_buffer_discard, duration_us: 10_000}
                    }}

    fresh = %{old | stream_id: "fresh", data: :binary.copy(<<2, 0>>, 240)}
    :ok = MemoryAudio.audio(channel, fresh)
    eventually(fn -> :sys.get_state(provider).outbound.bytes == byte_size(fresh.data) end, 200)
    assert [^fresh] = MemoryAudio.drain(provider)
    assert Process.alive?(pid)
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    unless fun.() do
      Process.sleep(5)
      eventually(fun, attempts - 1)
    end
  end
end
