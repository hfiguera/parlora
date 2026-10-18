defmodule OrderDesk.ClarificationCoverageLifecycleTest do
  use ExUnit.Case
  alias OrderDesk.{AppPolicy, ScriptedProvider}

  test "a real session rechecks a covered question once and recovers without a backend action" do
    owner = self()
    {:ok, clock} = Agent.start_link(fn -> nil end)
    on_exit(fn -> if Process.alive?(clock), do: Agent.stop(clock) end)

    window = fn _ ->
      now = System.monotonic_time(:millisecond)

      Agent.get_and_update(clock, fn due ->
        due = due || now + 120
        {max(0, due - now), due}
      end)
    end

    {:ok, session} =
      OrderDesk.start_session(
        {Parlora.Channels.LocalAudio, device: :synthetic},
        {ScriptedProvider, observer: self(), audio: false},
        context: %{voice_provider: :gemini},
        context_policy:
          {AppPolicy,
           [
             classify: fn _ -> {:ok, %{intent: "status", order: "unknown"}} end,
             clarification_settle_ms: 20,
             clarification_verify_ms: 20,
             clarification_window: window,
             clarification_judge: fn _ ->
               send(owner, :coverage_judged)
               {:ok, "covered"}
             end
           ]}
      )

    on_exit(fn -> if Process.alive?(session), do: Parlora.close(session, :cancel) end)
    assert_receive {:scripted_provider, provider}
    assert_receive {:parlora_event, %{source: :session, type: :ready}}, 1_000
    init = :sys.get_state(provider).init
    Parlora.Event.emit(init, :provider, :provider_speech, %{state: :idle})

    ScriptedProvider.transcript(provider, %{
      speaker: :user,
      delta: "Check my order",
      timing: :unavailable
    })

    ScriptedProvider.transcript(provider, %{
      speaker: :assistant,
      delta: "Please tell me the order number.",
      timing: :unavailable
    })

    ScriptedProvider.delegate(provider, "missing-number")
    assert_receive :coverage_judged, 1_000

    assert_receive {:parlora_event,
                    %{type: :context_wait_started, payload: %{recheck_after_ms: delay}}}
                   when delay <= 120,
                   1_000

    assert_receive {:context, update}, 1_000
    assert update.content =~ "three-digit order number"
    assert map_size(Parlora.status(session).jobs) == 0
    assert_receive {:parlora_event, %{type: :clarification_requested}}, 1_000
    refute_receive :coverage_judged, 150
    refute_receive {:context, _}, 150
  end
end
