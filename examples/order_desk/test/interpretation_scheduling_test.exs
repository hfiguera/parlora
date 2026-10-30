defmodule OrderDesk.InterpretationSchedulingTest do
  use ExUnit.Case
  alias OrderDesk.Interpretation
  alias Parlora.{ContextSnapshot, ContextTrigger}

  defmodule Snapshot do
    use GenServer
    def start_link(id), do: GenServer.start_link(__MODULE__, id)
    def init(id), do: {:ok, %ContextSnapshot{session_id: id, revision: 1}}
    def handle_call(:snapshot, _from, state), do: {:reply, state, state}

    def handle_call(:revise, _from, state),
      do: {:reply, :ok, %{state | revision: state.revision + 1}}
  end

  defmodule Client do
    use GenServer
    def start_link(owner), do: GenServer.start_link(__MODULE__, owner, name: OrderDesk.TypeSafe)
    def init(owner), do: {:ok, owner}

    def handle_call({:evaluate, _request}, from, owner) do
      send(owner, {:evaluation, from})
      {:noreply, owner}
    end
  end

  setup do
    start_supervised!({Client, self()})
    id = Parlora.ID.new()
    session = start_supervised!({Snapshot, id})
    :ok = Interpretation.attach(session, "owner-#{id}")
    %{session: session, id: id, actor: "owner-#{id}"}
  end

  defp classify(id, options \\ []) do
    Interpretation.classify(
      %{active_task: nil, recent_work: [], order_candidates: ["124"]},
      Keyword.merge([session_id: id, context_revision: 1], options)
    )
  end

  test "a revised snapshot skips the network request after coalescing", c do
    owner = self()

    current? = fn ->
      value = Interpretation.current?(c.id, 1)
      send(owner, :checked)
      value
    end

    task = Task.async(fn -> classify(c.id, current?: current?) end)
    assert_receive :checked
    :ok = GenServer.call(c.session, :revise)
    assert Task.await(task) == {:error, :superseded}
    refute_receive {:evaluation, _}, 30
    assert %{sessions: [%{metrics: %{calls: 0, skipped: 1}}]} = Interpretation.stats(c.actor)
  end

  test "work made stale during inference is discarded and reported separately", c do
    task = Task.async(fn -> classify(c.id) end)
    assert_receive {:evaluation, from}, 1_000
    :ok = GenServer.call(c.session, :revise)
    GenServer.reply(from, {:error, TypeSafe.Error.new(:timeout, "Fixture timeout")})
    assert Task.await(task) == {:error, :superseded}

    assert %{sessions: [%{metrics: %{calls: 1, errors: 1, uncertain: 0, stale: 1}}]} =
             Interpretation.stats(c.actor)

    assert Interpretation.stats("another-owner").sessions == []
  end

  test "uncertainty is counted separately from errors and cached within its session", c do
    task = Task.async(fn -> classify(c.id) end)
    assert_receive {:evaluation, from}, 1_000

    answer = fn choice, confidence ->
      %{choice: choice, probabilities: %{choice => confidence}}
    end

    GenServer.reply(
      from,
      {:ok, %{answers: %{"intent" => answer.("items", 0.6), "target" => answer.("124", 0.9)}}}
    )

    assert {:error, {:uncertain, _}} = Task.await(task)
    assert {:error, {:uncertain, _}} = classify(c.id)
    refute_receive {:evaluation, _}, 30

    assert %{sessions: [%{metrics: %{calls: 1, hits: 1, errors: 0, uncertain: 1}}]} =
             Interpretation.stats(c.actor)
  end

  test "fresh verification and another session never reuse a cached judgment", c do
    run = fn id, options ->
      task = Task.async(fn -> classify(id, options) end)
      assert_receive {:evaluation, from}, 1_000
      GenServer.reply(from, {:error, TypeSafe.Error.new(:timeout, "Fixture timeout")})
      assert Task.await(task) == {:error, :timeout}
    end

    run.(c.id, [])
    assert classify(c.id) == {:error, :timeout}
    run.(c.id, fresh?: true)

    other = Parlora.ID.new()
    session = start_supervised!({Snapshot, other}, id: other)
    :ok = Interpretation.attach(session, "other-owner")
    run.(other, [])
    assert %{sessions: [%{metrics: %{calls: 2, hits: 1}}]} = Interpretation.stats(c.actor)

    assert %{sessions: [%{session_id: ^other, metrics: %{calls: 1, hits: 0}}]} =
             Interpretation.stats("other-owner")
  end

  test "closing a session makes in-flight work stale and retains observations", c do
    GenServer.stop(c.session)
    assert {:error, :superseded} = classify(c.id)
    assert %{sessions: [%{closed: true}]} = Interpretation.stats(c.actor)
  end

  test "a deferred real session resumes after speech ends without another caller event" do
    owner = self()

    {:ok, session} =
      OrderDesk.start_session(
        {Parlora.Channels.LocalAudio, device: :synthetic},
        {OrderDesk.ScriptedProvider, observer: self(), audio: false},
        context_policy:
          {OrderDesk.AppPolicy,
           classify: fn _ ->
             send(owner, {:classification, self()})

             receive do
               {:classified, result} -> result
             end
           end}
      )

    on_exit(fn -> if Process.alive?(session), do: Parlora.close(session) end)
    assert_receive {:scripted_provider, provider}, 1_000
    assert_receive {:parlora_event, %{source: :session, type: :ready}}, 1_000
    init = :sys.get_state(provider).init
    Parlora.Event.emit(init, :provider, :provider_speech, %{state: :speaking})

    OrderDesk.ScriptedProvider.transcript(provider, %{
      speaker: :user,
      delta: "What items are in order 124?",
      timing: :unavailable
    })

    OrderDesk.ScriptedProvider.delegate(provider, "deferred")
    assert_receive {:classification, first}, 1_000

    OrderDesk.ScriptedProvider.transcript(provider, %{
      speaker: :assistant,
      delta: "Let me check",
      timing: :unavailable
    })

    assert_receive {:parlora_event, %{type: :transcript_delta, payload: %{speaker: :assistant}}},
                   1_000

    send(first, {:classified, {:error, :superseded}})
    assert_receive {:parlora_event, %{type: :context_wait_started}}, 1_000
    refute_receive {:classification, _}, 250
    Parlora.Event.emit(init, :provider, :provider_speech, %{state: :idle})
    assert_receive {:classification, resumed}, 1_000
    send(resumed, {:classified, {:ok, %{intent: "items", order: "124"}}})
    assert_receive {:parlora_event, %{type: :task_submitted, payload: %{request: request}}}, 1_000
    assert request.input.order == "124"
  end

  test "streamed assistant captions defer only when speech state is known" do
    for provider <- [:openai, :gemini, :grok, :phonic] do
      snapshot = %ContextSnapshot{
        session_id: Parlora.ID.new(),
        provider_speech: :speaking,
        application_context: %{voice_provider: provider},
        transcripts: [
          %{speaker: :assistant, delta: "Lemme pull", arrival_order: 2},
          %{speaker: :user, delta: "What items are in order 124?", arrival_order: 1}
        ],
        pending_delegations: %{"call" => %{status: :pending}}
      }

      classifier = fn _ ->
        send(self(), :classified)
        {:ok, %{intent: "items", order: "124"}}
      end

      assert {:ok, [%{kind: :wait_for_context, recheck_after_ms: 200}]} =
               OrderDesk.AppPolicy.interpret(snapshot, %ContextTrigger{kind: :transcript_updated},
                 classify: classifier
               )

      refute_received :classified

      for kind <- [:delegation, :backend_clarification, :application_context_updated] do
        assert {:ok, [%{kind: :start_task}]} =
                 OrderDesk.AppPolicy.interpret(snapshot, %ContextTrigger{kind: kind},
                   classify: classifier
                 )

        assert_received :classified
      end

      for speech <- [:idle, :unknown] do
        assert {:ok, [%{kind: :start_task}]} =
                 OrderDesk.AppPolicy.interpret(
                   %{snapshot | provider_speech: speech},
                   %ContextTrigger{},
                   classify: classifier
                 )

        assert_received :classified
      end

      caller = %{speaker: :user, delta: "Actually check order 825", arrival_order: 3}

      assert {:ok, [%{kind: :start_task}]} =
               OrderDesk.AppPolicy.interpret(
                 %{snapshot | transcripts: [caller | snapshot.transcripts]},
                 %ContextTrigger{},
                 classify: classifier
               )

      assert_received :classified
    end
  end
end
