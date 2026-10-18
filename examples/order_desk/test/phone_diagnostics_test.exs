defmodule OrderDesk.PhoneDiagnosticsTest do
  use ExUnit.Case, async: false
  alias OrderDesk.PhoneDiagnostics

  test "backend result structs do not terminate the observer or discard call evidence" do
    observer = start_supervised!(PhoneDiagnostics)

    {:ok, session} =
      OrderDesk.start_session(
        {Parlora.Channels.LocalAudio, device: :synthetic},
        {OrderDesk.ScriptedProvider, observer: self(), audio: false}
      )

    on_exit(fn ->
      if Process.alive?(session), do: Parlora.close(session)
    end)

    :ok = PhoneDiagnostics.attach(session)
    id = Parlora.snapshot(session).session_id

    send(
      observer,
      {:parlora_event,
       %Parlora.Event{
         session_id: id,
         source: :backend,
         type: :request_completed,
         request_id: "request",
         payload: %Parlora.BackendResult{
           request_id: "request",
           status: :completed,
           summary: "Private business result must not be copied into diagnostics"
         }
       }}
    )

    send(
      observer,
      {:parlora_event,
       %Parlora.Event{
         session_id: id,
         source: :channel,
         type: :failed,
         payload: %{
           error: %Parlora.Error{
             code: :timeout,
             message: "Private transport data",
             details: %{
               reason: :playback_ack_timeout,
               pending_marks: 25,
               inflight_bytes: 4_000,
               private: "Do not retain"
             }
           }
         }
       }}
    )

    send(
      observer,
      {:parlora_event,
       %Parlora.Event{
         session_id: id,
         source: :channel,
         type: :audio_discontinuity,
         payload: %{
           cause: :output_stale,
           dropped_bytes: 160,
           dropped_frames: 1,
           dropped_duration_us: 20_000
         }
       }}
    )

    state = PhoneDiagnostics.snapshot()
    assert Process.alive?(observer)
    assert Enum.any?(state[id].events, &(&1.type == :request_completed))
    refute Jason.encode!(state) =~ "Private business result"
    refute Jason.encode!(state) =~ "Private transport data"
    refute Jason.encode!(state) =~ "Do not retain"

    assert Enum.any?(
             state[id].events,
             &match?(
               %{
                 type: :failed,
                 payload: %{
                   error: %{details: %{reason: :playback_ack_timeout, pending_marks: 25}}
                 }
               },
               &1
             )
           )

    assert Enum.any?(
             state[id].events,
             &match?(
               %{
                 type: :audio_discontinuity,
                 payload: %{cause: :output_stale, dropped_bytes: 160, dropped_duration_us: 20_000}
               },
               &1
             )
           )
  end
end
