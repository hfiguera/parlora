defmodule BookingDesk.CallGuardTest do
  use ExUnit.Case, async: false
  alias BookingDesk.CallGuard
  alias BookingDesk.CallGuard.Classifier
  alias Parlora.{ContextSnapshot, Event}

  defmodule Transport do
    use GenServer
    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)

    def init(owner),
      do: {:ok, %{owner: owner, snapshot: %ContextSnapshot{session_id: "guard-test"}}}

    def snapshot(pid), do: GenServer.call(pid, :snapshot)
    def put(pid, snapshot), do: GenServer.call(pid, {:put, snapshot})
    def control(pid, value), do: GenServer.call(pid, {:action, {:control, value}})

    def append_context(pid, %{kind: :instruction} = value),
      do: GenServer.call(pid, {:action, {:instruction, value.content}})

    def append_context(pid, value), do: GenServer.call(pid, {:action, {:message, value.content}})
    def close(pid, value), do: GenServer.call(pid, {:action, {:closed, value}})
    def handle_call(:snapshot, _, s), do: {:reply, s.snapshot, s}
    def handle_call({:put, snapshot}, _, s), do: {:reply, :ok, %{s | snapshot: snapshot}}

    def handle_call({:action, action}, _, s) do
      send(s.owner, {:guard_action, action})
      {:reply, :ok, s}
    end
  end

  defp snapshot(text, cursor, generation \\ 0) do
    %ContextSnapshot{
      session_id: "guard-test",
      provider_generation: generation,
      transcripts: [%{speaker: :user, delta: text, arrival_order: cursor}]
    }
  end

  defp start(evaluator, opts \\ []) do
    transport = start_supervised!(Supervisor.child_spec({Transport, self()}, id: make_ref()))

    guard =
      start_supervised!(
        Supervisor.child_spec(
          {CallGuard,
           Keyword.merge(
             [
               event_sink: self(),
               transport: Transport,
               evaluator: evaluator,
               debounce_ms: 0,
               quiet_ms: 20,
               delivery_ms: 1_000
             ],
             opts
           )},
          id: make_ref()
        )
      )

    :ok = CallGuard.bind(guard, transport)
    {guard, transport}
  end

  defp check(guard, transport, snapshot) do
    Transport.put(transport, snapshot)
    CallGuard.check(guard, snapshot)
  end

  defp eventually(f, tries \\ 100) do
    if f.() do
      :ok
    else
      if tries == 0, do: flunk("guard did not settle")
      Process.sleep(10)
      eventually(f, tries - 1)
    end
  end

  defp caption(guard, text) do
    send(
      guard,
      {:parlora_event,
       %Event{type: :transcript_delta, payload: %{speaker: :assistant, delta: text}}}
    )
  end

  defp voice(guard) do
    observer = CallGuard.observer(guard)

    Parlora.AudioObserver.send_audio(
      observer,
      :output,
      :binary.copy(<<1000::signed-little-16>>, 240)
    )
  end

  defp finish_message(guard, text) do
    caption(guard, text)
    voice(guard)
    eventually(fn -> :sys.get_state(guard).announcement == nil end)
  end

  defp answer(choice, probability \\ 0.99),
    do: %{choice: choice, probabilities: %{choice => probability}}

  test "replay software playout reaches the guard and its existing recording tap" do
    outer = %{pid: self(), credits: :atomics.new(2, [])}
    {g, t} = start(fn _ -> {:ok, :emergency} end, audio_observer: outer)
    check(g, t, snapshot("I need emergency help", 1))
    assert_receive {:guard_action, {:message, _}}

    init = %Parlora.AdapterInit{
      session_id: "guard-replay",
      adapter_id: "replay",
      generation: 0,
      event_sink: self(),
      audio_format: %Parlora.AudioFormat{},
      limits: %Parlora.Limits{}
    }

    {:ok, channel} =
      BookingDesk.ReplayChannel.start_link(init,
        owner: self(),
        audio_observer: CallGuard.observer(g),
        observer: %{pid: self(), credits: :atomics.new(2, [])}
      )

    try do
      pcm = :binary.copy(<<1000::signed-little-16>>, 240)
      frame = Parlora.AudioFrame.pcm(pcm, "assistant", 0, playback_epoch: 0)
      assert :ok = BookingDesk.ReplayChannel.write_audio(channel, frame)
      eventually(fn -> :sys.get_state(g).announcement.heard end)
      assert_receive {:parlora_audio, :output, _, ^pcm}, 500
      refute_receive {:guard_action, {:closed, _}}, 30
    after
      GenServer.stop(channel)
    end
  end

  test "JEV emergency choice wins over abuse; uncertainty cannot authorize scheduling" do
    assert {:ok, :emergency} =
             Classifier.decode(%{"emergency" => answer("yes"), "conduct" => answer("abuse")})

    assert {:ok, :possible_emergency} =
             Classifier.decode(%{
               "emergency" => answer("uncertain"),
               "conduct" => answer("allowed")
             })

    assert {:ok, :allowed} =
             Classifier.decode(%{"emergency" => answer("no"), "conduct" => answer("allowed")})

    assert {:error, :uncertain} =
             Classifier.decode(%{"emergency" => answer("no"), "conduct" => answer("abuse", 0.6)})

    assert {:error, :uncertain} = Classifier.decode(%{})
    assert Classifier.questions()["emergency"]
    assert Classifier.questions()["conduct"]
  end

  test "off-topic without a tool delegation redirects, then a scheduling reply can recover" do
    {g, t} =
      start(fn %{latest_user: text} ->
        {:ok, if(text == "Tell me about baseball", do: :off_topic, else: :allowed)}
      end)

    first = snapshot("Tell me about baseball", 1)
    assert :wait = check(g, t, first)
    assert_receive {:guard_action, {:message, text}}
    assert text =~ "clinic appointments"
    assert :blocked = CallGuard.check(g, first)
    assert :wait = check(g, t, snapshot("An appointment with Dr. Lee", 2))
    eventually(fn -> CallGuard.check(g, snapshot("An appointment with Dr. Lee", 2)) == :allow end)
    refute_receive {:guard_action, {:closed, _}}, 30
  end

  test "caller-fragment rechecks cannot multiply abuse warnings; repeated abuse closes after playout" do
    {g, t} = start(fn _ -> {:ok, :abuse} end)
    first = snapshot("Directed insult", 1)
    check(g, t, first)
    assert_receive {:guard_action, {:message, warning}}
    assert warning =~ "If it continues"
    for _ <- 1..5, do: assert(:blocked == CallGuard.check(g, first))
    # A new fragment while that same warning is still being delivered is not a new strike.
    check(g, t, snapshot("Directed insult continued", 2))
    eventually(fn -> :sys.get_state(g).job == nil and :sys.get_state(g).timer == nil end)
    assert :sys.get_state(g).abuse == 1
    finish_message(g, CallGuard.message(:abuse_warning))
    check(g, t, snapshot("Another directed insult", 3))
    assert_receive {:guard_action, {:message, closing}}
    assert closing =~ "ending this call"
    refute_receive {:guard_action, {:closed, _}}, 40
    caption(g, "Goodbye.")

    for _ <- 1..8 do
      voice(g)
      Process.sleep(15)
    end

    refute_receive {:guard_action, {:closed, _}}, 5
    assert_receive {:guard_action, {:closed, :finish}}, 500
  end

  test "a failed warning delivery is not counted as a warning the caller heard" do
    {g, t} = start(fn _ -> {:ok, :abuse} end, delivery_ms: 30)
    check(g, t, snapshot("Insult", 1))
    assert_receive {:guard_action, {:message, _}}
    eventually(fn -> :sys.get_state(g).announcement == nil end)
    assert :sys.get_state(g).abuse == 0
    refute_receive {:guard_action, {:closed, _}}, 20
  end

  test "an emergency overrides an abuse closing and blocks all subsequent booking decisions" do
    {g, t} =
      start(fn %{latest_user: text} ->
        {:ok, if(text == "I cannot breathe", do: :emergency, else: :abuse)}
      end)

    check(g, t, snapshot("Insult", 1))
    assert_receive {:guard_action, {:message, _}}
    finish_message(g, CallGuard.message(:abuse_warning))
    check(g, t, snapshot("Another insult", 2))
    assert_receive {:guard_action, {:message, _}}
    check(g, t, snapshot("I cannot breathe", 3))
    assert_receive {:guard_action, {:message, text}}
    assert text =~ "call 911 now"
    assert text =~ "cannot call or transfer"
    assert :sys.get_state(g).closing == :emergency
    assert_receive {:guard_action, {:control, {:input_muted, true}}}
    assert :blocked = check(g, t, snapshot("Book it anyway", 4))
    finish_message(g, text)
    assert_receive {:guard_action, {:closed, :finish}}, 500
  end

  test "a slow classification from an older caller revision cannot issue a warning" do
    parent = self()

    {g, t} =
      start(fn input ->
        send(parent, {:classifying, self(), input.latest_user})

        receive do
          :finish -> {:ok, :abuse}
        end
      end)

    check(g, t, snapshot("Old words", 1))
    assert_receive {:classifying, worker, _}
    Transport.put(t, snapshot("New scheduling request", 2))
    send(worker, :finish)
    eventually(fn -> :sys.get_state(g).job == nil end)
    refute_receive {:guard_action, {:message, _}}, 50
    assert :sys.get_state(g).abuse == 0
  end

  test "classifier timeout holds booking and uses a bounded unavailable closing" do
    {g, t} =
      start(
        fn _ ->
          receive do
            :never -> {:ok, :allowed}
          end
        end,
        timeout_ms: 20,
        delivery_ms: 30
      )

    first = snapshot("Book an appointment", 1)
    assert :wait = check(g, t, first)
    assert_receive {:guard_action, {:message, message}}
    assert message =~ "unable to handle"
    assert :blocked = CallGuard.check(g, first)
    assert_receive {:guard_action, {:closed, :finish}}, 500
  end

  test "policy gates delegated backend work before identity interpretation and fails closed if guard exits" do
    {g, t} = start(fn _ -> {:ok, :off_topic} end)

    s = %{
      snapshot("Baseball", 1)
      | pending_delegations: %{"d" => %{status: :pending, received_at_us: 1}}
    }

    Transport.put(t, s)

    assert {:ok, [decision]} =
             BookingDesk.Policy.interpret(s, %Parlora.ContextTrigger{kind: :delegation},
               call_guard: g,
               judge: fn _ -> flunk("booking classifier must not run") end
             )

    assert decision.kind == :wait_for_context
    GenServer.stop(g)

    assert {:error, %Parlora.Error{}} =
             BookingDesk.Policy.interpret(s, %Parlora.ContextTrigger{kind: :delegation},
               call_guard: g
             )
  end

  test "the guard forwards exact PCM and timestamp to the existing recording observer" do
    outer = %{pid: self(), credits: :atomics.new(2, [])}
    {g, _} = start(fn _ -> {:ok, :allowed} end, audio_observer: outer)
    observer = CallGuard.observer(g)
    :atomics.add(observer.credits, 1, 1)
    send(g, {:parlora_audio, :input, 12_345, <<1, 0, 2, 0>>})
    assert_receive {:parlora_audio, :input, 12_345, <<1, 0, 2, 0>>}
    :atomics.sub(outer.credits, 1, 1)
    assert :atomics.get(observer.credits, 1) == 0
  end

  test "two delivered off-topic redirects are followed by an announced closure" do
    {g, t} = start(fn _ -> {:ok, :off_topic} end)

    for cursor <- 1..2 do
      check(g, t, snapshot("More baseball", cursor))
      assert_receive {:guard_action, {:message, text}}
      refute text =~ "ending the call"
      finish_message(g, CallGuard.message(:scope_redirect))
    end

    check(g, t, snapshot("Still baseball", 3))
    assert_receive {:guard_action, {:message, text}}
    assert text =~ "ending the call"
    refute_receive {:guard_action, {:closed, _}}, 30
    caption(g, "Goodbye.")
    voice(g)
    assert_receive {:guard_action, {:closed, :finish}}, 500
  end

  test "a medical-advice redirect never claims to diagnose or close an ordinary inquiry" do
    {g, t} = start(fn _ -> {:ok, :medical_question} end)
    check(g, t, snapshot("Which medicine should I take?", 1))
    assert_receive {:guard_action, {:message, text}}
    assert text =~ "cannot provide medical advice"
    assert text =~ "qualified medical professional"
    assert :sys.get_state(g).abuse == 0
    refute_receive {:guard_action, {:closed, _}}, 30
  end

  test "ordinary frustration and brief social replies permit the scheduling policy without a warning" do
    {g, t} = start(fn _ -> {:ok, :allowed} end)

    s = %{
      snapshot("This paperwork is frustrating. I need an appointment.", 1)
      | pending_delegations: %{"d" => %{status: :pending, received_at_us: 1}}
    }

    check(g, t, s)
    eventually(fn -> CallGuard.check(g, s) == :allow end)
    parent = self()

    assert {:ok, []} =
             BookingDesk.Policy.interpret(s, %Parlora.ContextTrigger{kind: :delegation},
               call_guard: g,
               coalesce_ms: 0,
               judge: fn _ ->
                 send(parent, :scheduling_interpreted)
                 {:ok, %{"intent" => "none"}}
               end
             )

    assert_receive :scheduling_interpreted
    refute_receive {:guard_action, {:message, _}}, 30
  end

  test "evaluation budgets fail closed rather than authorizing unclassified requests" do
    {g, t} = start(fn _ -> {:ok, :allowed} end, max_evaluations: 1)
    check(g, t, snapshot("First reply", 1))
    eventually(fn -> CallGuard.check(g, snapshot("First reply", 1)) == :allow end)
    check(g, t, snapshot("Next reply", 2))
    assert_receive {:guard_action, {:message, text}}
    assert text =~ "unable to handle"
    assert :blocked = CallGuard.check(g, snapshot("Next reply", 2))
  end

  test "an obsolete provider generation cannot apply a classification" do
    parent = self()

    {g, t} =
      start(fn _ ->
        send(parent, {:worker, self()})

        receive do
          :finish -> {:ok, :abuse}
        end
      end)

    check(g, t, snapshot("Words", 1, 0))
    assert_receive {:worker, worker}
    Transport.put(t, snapshot("Words", 1, 1))
    send(worker, :finish)
    eventually(fn -> :sys.get_state(g).job == nil end)
    refute_receive {:guard_action, {:message, _}}, 30
    assert :sys.get_state(g).abuse == 0
  end

  test "warnings are isolated between simultaneous calls" do
    {g1, t1} = start(fn _ -> {:ok, :abuse} end)
    {g2, t2} = start(fn _ -> {:ok, :abuse} end)
    check(g1, t1, snapshot("Insult", 1))
    assert_receive {:guard_action, {:message, _}}
    check(g2, t2, snapshot("Insult", 1))
    assert_receive {:guard_action, {:message, _}}
    assert :sys.get_state(g1).abuse == 1
    assert :sys.get_state(g2).abuse == 1
    refute_receive {:guard_action, {:closed, _}}, 30
  end

  test "emergency latch survives provider reconnection and holds existing result delivery" do
    {g, t} = start(fn _ -> {:ok, :emergency} end)
    check(g, t, snapshot("An emergency", 1))
    assert_receive {:guard_action, {:message, _}}
    reconnect = snapshot("Book it", 2, 1)
    assert :blocked = check(g, t, reconnect)
    assert_receive {:guard_action, {:message, message}}
    assert message =~ "call 911"

    s = %{
      reconnect
      | tasks: %{
          "t" => %{
            id: "t",
            revision: 1,
            status: :completed,
            input: %{operation: "availability", cursor: 1}
          }
        }
    }

    assert {:ok, [decision]} =
             BookingDesk.Policy.interpret(s, %Parlora.ContextTrigger{kind: :transcript_updated},
               call_guard: g,
               judge: fn _ -> flunk("emergency must bypass scheduling") end
             )

    assert decision.kind == :wait_for_context
    assert decision.task_id == "t"
  end

  test "guard tap packet loss is propagated to the explicit recording observer" do
    outer = %{pid: self(), credits: :atomics.new(2, [])}
    {g, _} = start(fn _ -> {:ok, :allowed} end, audio_observer: outer)
    observer = CallGuard.observer(g)
    :atomics.add(observer.credits, 2, 3)
    :atomics.add(observer.credits, 1, 1)
    send(g, {:parlora_audio, :output, 123, <<0, 0>>})
    assert_receive {:parlora_audio, :output, 123, <<0, 0>>}
    assert :atomics.get(outer.credits, 2) == 3
    :atomics.sub(outer.credits, 1, 1)
  end

  test "an emergency closing cannot become a silent blocked patient lookup" do
    {g, t} = start(fn _ -> {:ok, :emergency} end, instruction_updates: true)
    check(g, t, snapshot("Help, this is an emergency", 1))
    assert_receive {:guard_action, {:control, {:input_muted, true}}}
    assert_receive {:guard_action, {:instruction, instruction}}
    assert instruction =~ "EMERGENCY CLOSING MODE"
    assert instruction =~ "Do not collect name/DOB"
    assert instruction =~ "patient lookups are blocked"
    assert_receive {:guard_action, {:message, guidance}}
    assert guidance =~ "hang up and call 911"
    refute_receive {:guard_action, {:closed, _}}, 40
    token = :sys.get_state(g).announcement.token

    for cursor <- 2..8 do
      assert :blocked =
               check(g, t, snapshot("Jamie Rivera, March 12, 1990. Pull my file.", cursor))
    end

    assert :sys.get_state(g).announcement.token == token
    assert :sys.get_state(g).evaluations == 1
    caption(g, "Please hang up and call 911. Goodbye.")
    voice(g)
    assert_receive {:guard_action, {:closed, :finish}}, 500
  end
end
