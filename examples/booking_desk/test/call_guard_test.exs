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
    def reject_next_message(pid, error), do: GenServer.call(pid, {:reject_next_message, error})

    def append_context(pid, %{kind: :instruction} = value),
      do: GenServer.call(pid, {:action, {:instruction, value.content}})

    def append_context(pid, %{kind: :quiet} = value),
      do: GenServer.call(pid, {:action, {:quiet, value}})

    def append_context(pid, value), do: GenServer.call(pid, {:action, {:message, value.content}})
    def close(pid, value), do: GenServer.call(pid, {:action, {:closed, value}})
    def handle_call(:snapshot, _, s), do: {:reply, s.snapshot, s}
    def handle_call({:put, snapshot}, _, s), do: {:reply, :ok, %{s | snapshot: snapshot}}

    def handle_call({:reject_next_message, error}, _, s),
      do: {:reply, :ok, Map.put(s, :message_error, error)}

    def handle_call({:action, {:message, _} = action}, _, %{message_error: error} = s) do
      send(s.owner, {:guard_action, action})
      {:reply, error, Map.delete(s, :message_error)}
    end

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

  defp pending_native_result(guard, transport, cursor \\ 1) do
    first = snapshot("Continue", cursor)
    check(guard, transport, first)
    eventually(fn -> CallGuard.check(guard, first) == :allow end)

    for stage <- [:awaiting_provider, :unconfirmed, :accepted] do
      send(
        guard,
        {:parlora_event,
         %Event{
           type: :result_delivery,
           request_id: "reminder-result",
           payload: %{stage: stage}
         }}
      )
    end
  end

  test "a false off-topic turn during a native result updates context without another spoken reply" do
    {g, t} =
      start(
        fn %{latest_user: text} ->
          {:ok, if(text == "I'm your interview rep.", do: :off_topic, else: :allowed)}
        end,
        native_result_replies: true
      )

    pending_native_result(g, t)
    latest = snapshot("I'm your interview rep.", 2)
    check(g, t, latest)
    assert_receive {:guard_action, {:quiet, update}}
    assert update.kind == :quiet
    assert update.content =~ "single current verified result"
    assert update.content =~ "grants no booking approval or reminder consent"
    assert :blocked = CallGuard.check(g, latest)
    assert :sys.get_state(g).off_topic == 0
    assert :sys.get_state(g).announcement == nil
    refute_receive {:guard_action, {:message, _}}, 30
    refute_receive {:guard_action, {:control, _}}, 30

    next = snapshot("No", 3)
    check(g, t, next)
    eventually(fn -> CallGuard.check(g, next) == :allow end)
  end

  test "a late scope classification cannot queue speech after the native question has already ended" do
    owner = self()

    {g, t} =
      start(
        fn %{latest_user: text} ->
          if text == "Continue" do
            {:ok, :allowed}
          else
            send(owner, {:scope_worker, self()})

            receive do
              :classify_now -> {:ok, :off_topic}
            end
          end
        end,
        native_result_replies: true
      )

    pending_native_result(g, t)
    check(g, t, snapshot("Background words", 2))
    assert_receive {:scope_worker, worker}

    for state <- [:speaking, :idle] do
      send(g, {:parlora_event, %Event{type: :provider_speech, payload: %{state: state}}})
    end

    assert :sys.get_state(g).native_reply.request_id == nil
    send(worker, :classify_now)
    assert_receive {:guard_action, {:quiet, _}}
    refute_receive {:guard_action, {:message, _}}, 30
  end

  test "an uncertain turn also cannot multiply a pending native question or grant task admission" do
    {g, t} =
      start(
        fn %{latest_user: text} ->
          if text == "Continue", do: {:ok, :allowed}, else: {:error, :uncertain}
        end,
        native_result_replies: true
      )

    pending_native_result(g, t)
    latest = snapshot("Unclear words", 2)
    check(g, t, latest)
    assert_receive {:guard_action, {:quiet, _}}
    assert CallGuard.check(g, latest) == :blocked
    refute_receive {:guard_action, {:message, _}}, 30
  end

  test "native response ownership never defers emergency guidance or an abuse warning" do
    for {kind, reason} <- [{:emergency, :emergency}, {:abuse, :abuse_warning}] do
      {g, t} =
        start(
          fn %{latest_user: text} ->
            {:ok, if(text == "Continue", do: :allowed, else: kind)}
          end,
          native_result_replies: true
        )

      pending_native_result(g, t)
      latest = snapshot("Urgent caller words", 2)
      check(g, t, latest)
      assert_receive {:guard_action, {:message, text}}, 500
      assert text =~ CallGuard.message(reason)
      assert :blocked = CallGuard.check(g, latest)
      refute_receive {:guard_action, {:quiet, _}}, 30
    end
  end

  test "unrelated captions and earlier audio cannot count as a delivered scope redirect" do
    {g, t} = start(fn _ -> {:ok, :off_topic} end, delivery_ms: 300)
    check(g, t, snapshot("Unrelated request", 1))
    assert_receive {:guard_action, {:message, _}}
    caption(g, "Can we send the reminder to the number ending in zero one eight eight?")
    voice(g)
    refute :sys.get_state(g).announcement.caption
    refute :sys.get_state(g).announcement.heard
    caption(g, CallGuard.message(:scope_redirect))
    refute :sys.get_state(g).announcement.heard
    eventually(fn -> :sys.get_state(g).announcement == nil end)
    assert :sys.get_state(g).off_topic == 0
  end

  test "manual response mode still asks a scope question when a result is submitted" do
    {g, t} =
      start(
        fn %{latest_user: text} ->
          {:ok, if(text == "Continue", do: :allowed, else: :off_topic)}
        end,
        native_result_replies: false
      )

    pending_native_result(g, t)
    check(g, t, snapshot("Unrelated request", 2))
    assert_receive {:guard_action, {:message, text}}
    assert text =~ CallGuard.message(:scope_redirect)
    refute_receive {:guard_action, {:quiet, _}}, 30
  end

  test "two delivered scope warnings still require closure even when a native result is pending" do
    {g, t} =
      start(
        fn %{latest_user: text} ->
          {:ok, if(text == "Continue", do: :allowed, else: :off_topic)}
        end,
        native_result_replies: true
      )

    for cursor <- 1..2 do
      check(g, t, snapshot("Unrelated request", cursor))
      assert_receive {:guard_action, {:message, _}}
      finish_message(g, CallGuard.message(:scope_redirect))
    end

    assert_receive {:guard_action, {:control, {:hold_output, :hold}}}
    pending_native_result(g, t, 3)
    assert_receive {:guard_action, {:control, {:hold_output, :play}}}

    send(
      g,
      {:parlora_event,
       %Event{type: :transcript_delta, payload: %{speaker: :user, delta: "Still unrelated"}}}
    )

    assert_receive {:guard_action, {:control, {:hold_output, :hold}}}
    check(g, t, snapshot("Still unrelated", 4))
    assert_receive {:guard_action, {:control, {:input_muted, true}}}
    assert_receive {:guard_action, {:message, text}}, 500
    assert text =~ CallGuard.message(:scope_close)
    assert :sys.get_state(g).closing == :scope_close
    refute_receive {:guard_action, {:quiet, _}}, 30
  end

  test "replay software playout reaches the guard and its existing recording tap" do
    outer = %{pid: self(), credits: :atomics.new(2, [])}
    {g, t} = start(fn _ -> {:ok, :emergency} end, audio_observer: outer)
    check(g, t, snapshot("I need emergency help", 1))
    assert_receive {:guard_action, {:message, _}}, 500
    caption(g, CallGuard.message(:emergency))

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

  test "Prism's current redirect finishes playing and counts once without a second announcement" do
    {g, t} = start(fn _ -> {:ok, :off_topic} end)
    question = "Hi, Ava. What do you know about soccer?"
    redirect = "I can help with clinic scheduling. What appointment help do you need?"

    send(
      g,
      {:parlora_event,
       %Event{type: :transcript_delta, generation: 0, payload: %{speaker: :user, delta: question}}}
    )

    send(g, {:parlora_event, %Event{type: :provider_speech, payload: %{state: :speaking}}})
    caption(g, redirect)
    voice(g)

    turn = snapshot(question, 1)
    assert :wait = check(g, t, turn)
    eventually(fn -> CallGuard.check(g, turn) == :blocked end)
    refute_receive {:guard_action, _}, 120
    assert :sys.get_state(g).off_topic == 0

    send(g, {:parlora_event, %Event{type: :provider_speech, payload: %{state: :idle}}})
    eventually(fn -> :sys.get_state(g).off_topic == 1 end)
    assert :blocked = CallGuard.check(g, turn)
    assert :sys.get_state(g).scope_reply == nil
    refute_receive {:guard_action, _}, 30
  end

  test "provider idle before the channel drains does not repeat the native baseball redirect" do
    {g, t} = start(fn _ -> {:ok, :off_topic} end, quiet_ms: 500)
    question = "Hi, Eva. What do you know about baseball?"

    send(
      g,
      {:parlora_event,
       %Event{type: :transcript_delta, generation: 0, payload: %{speaker: :user, delta: question}}}
    )

    turn = snapshot(question, 1)
    assert :wait = check(g, t, turn)
    eventually(fn -> CallGuard.check(g, turn) == :blocked end)
    send(g, {:parlora_event, %Event{type: :provider_speech, payload: %{state: :speaking}}})
    send(g, {:parlora_event, %Event{type: :provider_activity, payload: %{state: :in_progress}}})
    caption(g, CallGuard.message(:scope_redirect))
    voice(g)
    assert %{scope_reply: %{token: token, caption: true, has_audio: true}} = :sys.get_state(g)

    send(g, {:parlora_event, %Event{type: :provider_speech, payload: %{state: :idle}}})
    send(g, {:parlora_event, %Event{type: :provider_activity, payload: %{state: :idle}}})
    send(g, {:scope_tick, token})

    assert %{scope_reply: %{token: ^token}, announcement: nil, off_topic: 0} = :sys.get_state(g)

    send(
      g,
      {:parlora_event,
       %Event{
         source: :channel,
         type: :audio_discontinuity,
         observed_at_us: System.monotonic_time(:microsecond),
         payload: %{cause: :playback_starved}
       }}
    )

    eventually(fn -> :sys.get_state(g).off_topic == 1 end)
    refute_received {:guard_action, {:message, _}}
  end

  test "Prism scope fallback waits for idle and leaves its current output alone" do
    {g, t} = start(fn _ -> {:ok, :off_topic} end)

    send(
      g,
      {:parlora_event,
       %Event{type: :provider_speech, payload: %{state: :idle, typed_ready: true}}}
    )

    caption(g, CallGuard.message(:scope_redirect))
    send(g, {:parlora_event, %Event{type: :provider_speech, payload: %{state: :speaking}}})
    turn = snapshot("Soccer again?", 1)
    check(g, t, turn)
    eventually(fn -> CallGuard.check(g, turn) == :blocked end)

    caption(g, CallGuard.message(:scope_redirect) <> " Here's a soccer fact.")
    voice(g)
    refute_receive {:guard_action, _}, 120

    send(
      g,
      {:parlora_event,
       %Event{type: :provider_speech, payload: %{state: :idle, typed_ready: true}}}
    )

    expected = CallGuard.message(:scope_redirect)
    assert_receive {:guard_action, {:message, text}}, 500
    assert text =~ expected
    refute_receive {:guard_action, {:control, _}}, 30
    finish_message(g, expected)
    assert :sys.get_state(g).off_topic == 1
  end

  test "Prism counts a played warning before typed readiness and says goodbye on the third off-topic turn" do
    {g, t} =
      start(fn %{latest_user: text} ->
        {:ok, if(text == "Schedule an appointment", do: :allowed, else: :off_topic)}
      end)

    send(
      g,
      {:parlora_event,
       %Event{type: :provider_speech, payload: %{state: :idle, typed_ready: true}}}
    )

    warning = CallGuard.message(:scope_redirect)

    for {question, cursor} <- [{"Baseball?", 1}, {"Soccer?", 2}] do
      send(
        g,
        {:parlora_event,
         %Event{
           type: :transcript_delta,
           generation: 0,
           payload: %{speaker: :user, delta: question}
         }}
      )

      send(g, {:parlora_event, %Event{type: :provider_speech, payload: %{state: :speaking}}})
      turn = snapshot(question, cursor)
      check(g, t, turn)
      eventually(fn -> CallGuard.check(g, turn) == :blocked end)
      caption(g, warning)
      voice(g)

      send(
        g,
        {:parlora_event,
         %Event{type: :provider_activity, payload: %{state: :idle, status: "completed"}}}
      )

      at = System.monotonic_time(:microsecond)

      send(
        g,
        {:parlora_event,
         %Event{
           source: :channel,
           type: :audio_discontinuity,
           observed_at_us: at,
           payload: %{cause: :playback_starved}
         }}
      )

      send(g, {:parlora_event, %Event{type: :output_interrupted, observed_at_us: at + 100_000}})
      assert :sys.get_state(g).off_topic == cursor
    end

    assert_receive {:guard_action, {:control, {:hold_output, :hold}}}
    allowed = snapshot("Schedule an appointment", 3)
    check(g, t, allowed)
    assert_receive {:guard_action, {:control, {:hold_output, :play}}}
    assert :allow = CallGuard.check(g, allowed)

    send(
      g,
      {:parlora_event,
       %Event{
         type: :extension,
         payload: %{kind: :caller_speech, state: :started, segment_id: "hockey"}
       }}
    )

    assert_receive {:guard_action, {:control, {:hold_output, :hold}}}
    assert :wait = CallGuard.check(g, allowed)

    send(
      g,
      {:parlora_event,
       %Event{
         type: :transcript_delta,
         generation: 0,
         payload: %{speaker: :user, segment_id: "hockey", delta: "Hockey?"}
       }}
    )

    turn = snapshot("Hockey?", 4)
    check(g, t, turn)
    eventually(fn -> :sys.get_state(g).closing == :scope_close end)
    assert_receive {:guard_action, {:control, {:input_muted, true}}}
    send(g, {:parlora_event, %Event{type: :provider_speech, payload: %{state: :idle}}})
    refute_receive {:guard_action, _}, 120

    send(
      g,
      {:parlora_event,
       %Event{
         type: :provider_activity,
         payload: %{state: :idle, status: "completed", response_id: "held-redirect"}
       }}
    )

    assert_receive {:guard_action, {:control, {:clear_output, :next}}}, 500
    assert_receive {:guard_action, {:control, {:output_discarded, "held-redirect"}}}

    send(
      g,
      {:parlora_event,
       %Event{type: :provider_speech, payload: %{state: :idle, typed_ready: true}}}
    )

    goodbye = CallGuard.message(:scope_close)
    assert_receive {:guard_action, {:control, {:hold_output, :discard}}}, 500
    assert_receive {:guard_action, {:message, text}}, 500
    assert text =~ goodbye
    refute_receive {:guard_action, {:control, _}}, 30
    caption(g, goodbye)
    voice(g)
    assert_receive {:guard_action, {:closed, :finish}}, 500
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
    send(g, {:parlora_event, %Event{type: :provider_speech, payload: %{state: :speaking}}})
    caption(g, CallGuard.message(:abuse_close))
    voice(g)

    refute_receive {:guard_action, {:closed, _}}, 120
    send(g, {:parlora_event, %Event{type: :provider_speech, payload: %{state: :idle}}})
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
    assert_receive {:guard_action, {:message, text}}, 500
    assert text =~ "call 911 now"
    assert text =~ "cannot call or transfer"
    assert :sys.get_state(g).closing == :emergency
    assert_receive {:guard_action, {:control, {:input_muted, true}}}
    assert :blocked = check(g, t, snapshot("Book it anyway", 4))
    finish_message(g, CallGuard.message(:emergency))
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

  test "after two delivered redirects, the generic hold drops the reply before the goodbye" do
    {g, t} = start(fn _ -> {:ok, :off_topic} end)

    for cursor <- 1..2 do
      check(g, t, snapshot("More baseball", cursor))
      assert_receive {:guard_action, {:message, text}}
      refute text =~ "ending the call"
      finish_message(g, CallGuard.message(:scope_redirect))
    end

    assert_receive {:guard_action, {:control, {:hold_output, :hold}}}
    send(g, {:parlora_event, %Event{type: :provider_speech, payload: %{state: :speaking}}})
    check(g, t, snapshot("Still baseball", 3))
    assert_receive {:guard_action, {:control, {:input_muted, true}}}
    refute_receive {:guard_action, {:control, {:hold_output, :discard}}}, 120
    refute_received {:guard_action, {:message, _}}

    send(g, {:parlora_event, %Event{type: :provider_speech, payload: %{state: :idle}}})
    assert_receive {:guard_action, {:control, {:hold_output, :discard}}}, 500
    assert_receive {:guard_action, {:message, text}}, 500
    assert text =~ "ending the call"
    refute_receive {:guard_action, {:closed, _}}, 30
    goodbye = CallGuard.message(:scope_close) |> String.replace("I am", "I’m")
    caption(g, goodbye)
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
    assert_receive {:guard_action, {:message, _}}, 500
    reconnect = snapshot("Book it", 2, 1)
    assert :blocked = check(g, t, reconnect)
    assert_receive {:guard_action, {:message, message}}, 500
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
    assert_receive {:guard_action, {:instruction, instruction}}, 500
    assert instruction =~ "EMERGENCY CLOSING MODE"
    assert instruction =~ "Do not collect name/DOB"
    assert instruction =~ "patient lookups are blocked"
    assert_receive {:guard_action, {:message, guidance}}, 500
    assert guidance =~ "hang up and call 911"
    refute_receive {:guard_action, {:closed, _}}, 40
    token = :sys.get_state(g).announcement.token

    for cursor <- 2..8 do
      assert :blocked =
               check(g, t, snapshot("Jamie Rivera, March 12, 1990. Pull my file.", cursor))
    end

    assert :sys.get_state(g).announcement.token == token
    assert :sys.get_state(g).evaluations == 1
    caption(g, CallGuard.message(:emergency))
    voice(g)
    assert_receive {:guard_action, {:closed, :finish}}, 500
  end

  test "verified emergency guidance already in progress drains and closes without a replacement" do
    {g, t} =
      start(fn _ -> {:ok, :possible_emergency} end, delivery_ms: 100, instruction_updates: true)

    turn = snapshot("This is an emergency", 1)

    part = %{
      speaker: :assistant,
      delta: CallGuard.message(:possible_emergency),
      provider_generation: 0,
      arrival_order: 2
    }

    turn = %{turn | transcripts: [part | turn.transcripts]}

    send(g, {:parlora_event, %Event{type: :provider_speech, payload: %{state: :speaking}}})
    check(g, t, turn)
    assert_receive {:guard_action, {:control, {:input_muted, true}}}
    assert :blocked = CallGuard.check(g, turn)
    voice(g)
    refute_receive {:guard_action, _}, 120

    send(g, {:parlora_event, %Event{type: :provider_speech, payload: %{state: :idle}}})
    assert_receive {:guard_action, {:closed, :finish}}, 500
    refute_received {:guard_action, _}
  end

  test "emergency fallback waits for current speech and retries busy or superseded replies" do
    {g, t} = start(fn _ -> {:ok, :possible_emergency} end)
    busy = Parlora.Error.new(:backpressure, "Provider is busy")
    Transport.reject_next_message(t, {:error, busy})

    send(g, {:parlora_event, %Event{type: :provider_speech, payload: %{state: :speaking}}})
    check(g, t, snapshot("This is an emergency", 1))
    assert_receive {:guard_action, {:control, {:input_muted, true}}}
    caption(g, "If this is an emergency, please call 911.")
    voice(g)
    refute_receive {:guard_action, _}, 120

    send(g, {:parlora_event, %Event{type: :provider_speech, payload: %{state: :idle}}})
    assert_receive {:guard_action, {:message, _}}, 500
    assert_receive {:guard_action, {:message, text}}, 500
    assert text =~ CallGuard.message(:possible_emergency)

    eventually(fn -> :sys.get_state(g).announcement.phase == :submitted end)
    command = :sys.get_state(g).announcement.command_id

    superseded =
      Parlora.Error.new(:backpressure, "Prism did not start the reply", %{
        provider_code: "nudge_superseded"
      })

    send(g, {:parlora_event, %Event{type: :provider_speech, payload: %{state: :speaking}}})

    send(
      g,
      {:parlora_event,
       %Event{type: :context_rejected, command_id: command, payload: %{error: superseded}}}
    )

    refute_receive {:guard_action, _}, 120

    send(
      g,
      {:parlora_event,
       %Event{type: :provider_speech, payload: %{state: :idle, typed_ready: true}}}
    )

    assert_receive {:guard_action, {:message, ^text}}, 500
    refute :sys.get_state(g).announcement.command_id == command

    spoken =
      "Please hang up and call 911 now, or your local emergency number outside the United States. I cannot contact emergency services for you. Goodbye."

    finish_message(g, spoken)
    assert_receive {:guard_action, {:closed, :finish}}, 500
    refute_received {:guard_action, _}
  end

  test "retries accepted emergency guidance interrupted before audio and closes after the retry plays" do
    {g, t} = start(fn _ -> {:ok, :emergency} end)
    assert :wait = check(g, t, snapshot("I cannot breathe", 1))
    assert_receive {:guard_action, {:control, {:input_muted, true}}}
    assert_receive {:guard_action, {:message, guidance}}, 500
    assert guidance =~ CallGuard.message(:emergency)
    eventually(fn -> :sys.get_state(g).announcement.phase == :submitted end)
    first = :sys.get_state(g).announcement.command_id

    for event <- [
          %Event{
            type: :context_acknowledged,
            command_id: first,
            payload: %{acceptance: :response_created}
          },
          %Event{
            type: :provider_activity,
            payload: %{state: :in_progress, response_id: "guidance"}
          },
          %Event{type: :output_interrupted, payload: %{token: 1, response_id: "guidance"}},
          %Event{
            type: :provider_activity,
            payload: %{state: :idle, response_id: "guidance", status: "cancelled"}
          },
          %Event{type: :provider_speech, payload: %{state: :idle, typed_ready: true}}
        ] do
      send(g, {:parlora_event, event})
    end

    assert_receive {:guard_action, {:message, ^guidance}}, 500
    eventually(fn -> :sys.get_state(g).announcement.phase == :submitted end)
    assert :sys.get_state(g).announcement.command_id != first
    refute_receive {:guard_action, {:closed, _}}, 40

    finish_message(g, CallGuard.message(:emergency))
    assert_receive {:guard_action, {:closed, :finish}}, 500
    refute_received {:guard_action, _}
  end

  for trigger <- [:provider_timeout, :guard_deadline] do
    @timeout_trigger trigger
    test "retries timed-out emergency guidance once when #{trigger} arrives first" do
      {g, t} = start(fn _ -> {:ok, :emergency} end, delivery_ms: 450)
      assert :wait = check(g, t, snapshot("I cannot breathe", 1))
      assert_receive {:guard_action, {:control, {:input_muted, true}}}
      assert_receive {:guard_action, {:message, guidance}}, 500
      assert guidance =~ CallGuard.message(:emergency)

      accept = fn response_id ->
        eventually(fn -> :sys.get_state(g).announcement.phase == :submitted end)
        command = :sys.get_state(g).announcement.command_id

        send(
          g,
          {:parlora_event,
           %Event{
             type: :context_acknowledged,
             command_id: command,
             payload: %{acceptance: :response_created, response_id: response_id}
           }}
        )

        command
      end

      timeout = fn response_id ->
        send(
          g,
          {:parlora_event,
           %Event{
             type: :provider_activity,
             payload: %{
               state: :idle,
               response_id: response_id,
               status: "failed",
               reason: "response_timeout"
             }
           }}
        )
      end

      first = accept.("first")

      if @timeout_trigger == :provider_timeout do
        timeout.("unrelated")
        refute_receive {:guard_action, _}, 130
        timeout.("first")
      end

      assert_receive {:guard_action, {:message, ^guidance}}, 900
      assert accept.("retry") != first

      timeout.("first")
      refute_receive {:guard_action, _}, 130

      if @timeout_trigger == :provider_timeout do
        finish_message(g, CallGuard.message(:emergency))
      else
        timeout.("retry")
      end

      assert_receive {:guard_action, {:closed, :finish}}, 700
      refute_received {:guard_action, _}
    end
  end
end
