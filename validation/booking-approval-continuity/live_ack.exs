# Target the real post-registration approval step; no microphone or real SMS.
defmodule BookingDesk.ApprovalLiveProbe do
  alias BookingDesk.{Confirmation, Dialogue, Recorder, ReplayChannel, Store}
  alias Parlora.{ContextUpdate, Event, ID}

  def run(directory, audio) do
    {:ok, recorder} = Recorder.start_link(directory: directory)

    {:ok, session} =
      BookingDesk.start(
        {ReplayChannel, owner: self(), audio_observer: Recorder.observer(recorder)}
      )

    try do
      ready(recorder)
      id = Parlora.snapshot(session).session_id

      Store.execute(
        %{operation: "lookup", session: id, name: "Jamie Rivera", dob: "1990-03-12"},
        "probe-lookup"
      )

      insurance = Store.insurance("probe-lookup", id)

      Store.execute(
        %{
          operation: "insurance",
          session: id,
          patient: "p_1002",
          lookup_request: "probe-lookup",
          response: "unchanged",
          carrier: insurance.carrier,
          insurance_revision: insurance.revision
        },
        "probe-insurance"
      )

      :ok =
        Parlora.update_context(session, %{
          patient: "p_1002",
          lookup_request: "probe-lookup",
          insurance_request: "probe-insurance"
        })

      {_, channel} = :sys.get_state(session).adapters.channel

      :ok =
        Parlora.append_context(session, %ContextUpdate{
          id: ID.new(),
          kind: :instruction,
          provider_generation: 0,
          content:
            "The application has already completed this fictional caller's patient lookup and insurance review. Do not ask for those details again. Greet briefly as Ava and ask which appointment they need."
        })

      Process.send_after(self(), {:play, "search"}, 4_000)

      state = %{
        session: session,
        channel: channel,
        recorder: recorder,
        audio: audio,
        deadline: now() + 90_000,
        requests: %{},
        wait: nil,
        injected: false,
        ack_received: false,
        ack_before_booking: false,
        approval_cursor: nil,
        booking_cursor: nil,
        bookings: 0,
        clarifications: 0,
        code: nil,
        text: "",
        failures: 0
      }

      finish(loop(state))
    after
      if Process.alive?(session), do: Parlora.close(session)
    end
  end

  defp ready(recorder) do
    receive do
      {:parlora_event, %Event{source: :session, type: :ready} = e} ->
        Recorder.event(recorder, e)

      {:parlora_event, e} ->
        Recorder.event(recorder, e)
        ready(recorder)

      _ ->
        ready(recorder)
    after
      20_000 -> raise "Readiness timeout"
    end
  end

  defp loop(s) do
    if s.code && Confirmation.complete?(s.text, s.code) do
      s
    else
      receive do
        {:play, name} ->
          :ok =
            ReplayChannel.play(s.channel, File.read!(Path.join(s.audio, name <> ".pcm")), name)

          loop(s)

        {:parlora_event, e} ->
          Recorder.event(s.recorder, e)
          loop(attempt(event(s, e)))

        _ ->
          loop(s)
      after
        max(0, s.deadline - now()) -> s
      end
    end
  end

  defp event(s, %Event{type: :task_submitted, payload: %{request: r}}) do
    IO.puts("Task: " <> r.input.operation)
    s = put_in(s.requests[r.id], r.input.operation)

    if r.input.operation == "confirm",
      do: %{
        s
        | bookings: s.bookings + 1,
          booking_cursor: r.input.cursor,
          ack_before_booking: s.ack_received
      },
      else: s
  end

  defp event(s, %Event{source: :backend, type: :request_completed, request_id: id, payload: r}) do
    case s.requests[id] do
      "availability" ->
        Process.send_after(self(), {:play, "choose"}, 8_000)
        s

      "propose" ->
        Process.send_after(self(), {:play, "approve"}, 8_000)
        s

      "confirm" ->
        %{s | code: r.facts[:confirmation] || r.facts["confirmation"], text: ""}
    end
  end

  defp event(s, %Event{
         type: :context_wait_started,
         payload: %{target: {:task, task, _}, recheck_after_ms: 1_500}
       }),
       do: %{s | wait: task}

  defp event(s, %Event{type: :transcript_delta, payload: %{speaker: :user, delta: text}}),
    do: %{
      s
      | ack_received:
          s.ack_received or (s.injected and Regex.match?(~r/\b(?:okay|kay|ok)\b/i, text))
    }

  defp event(s, %Event{type: :transcript_delta, payload: %{speaker: :assistant, delta: text}}),
    do: %{s | text: s.text <> text}

  defp event(%{injected: true} = s, %Event{type: :clarification_requested}),
    do: %{s | clarifications: s.clarifications + 1}

  defp event(s, %Event{type: :failed}), do: %{s | failures: s.failures + 1}
  defp event(s, _), do: s
  defp attempt(%{injected: true} = s), do: s

  defp attempt(s) do
    snapshot = Parlora.snapshot(s.session)
    task = snapshot.tasks |> Map.values() |> Enum.max_by(& &1.input.cursor, fn -> nil end)
    caller = Dialogue.build(snapshot.transcripts, with_cursor: true) |> List.last()

    cursor =
      snapshot.transcripts
      |> Enum.filter(&(&1.speaker == :user))
      |> Enum.map(& &1.arrival_order)
      |> Enum.max(fn -> 0 end)

    acknowledgment =
      Enum.any?(snapshot.transcripts, &(&1.speaker == :assistant and &1.arrival_order > cursor))

    if match?(%{status: :completed, input: %{operation: "propose"}}, task) and task.id == s.wait and
         match?(%{speaker: :user}, caller) and Regex.match?(~r/\byes\b/i, caller.text) and
         acknowledgment do
      case ReplayChannel.play(s.channel, File.read!(Path.join(s.audio, "ack.pcm")), "ack") do
        :ok -> %{s | injected: true, approval_cursor: cursor}
        {:error, :busy} -> s
      end
    else
      s
    end
  end

  defp finish(s) do
    checks = %{
      ack_injected: s.injected,
      ack_transcribed_before_booking: s.ack_before_booking,
      booking_after_ack:
        s.injected and s.booking_cursor != nil and s.booking_cursor > s.approval_cursor,
      no_repeated_approval_question: s.clarifications == 0,
      one_booking_submission: s.bookings == 1,
      one_saved_booking:
        Enum.count(Store.snapshot(), fn [id, _, _, status, _] ->
          id != "appt_existing" and status == "booked"
        end) == 1,
      verified_receipt: s.code != nil and Confirmation.complete?(s.text, s.code),
      no_reminder_without_consent: Store.reminder_jobs() == [],
      no_adapter_failure: s.failures == 0
    }

    :ok = Parlora.close(s.session)
    Process.sleep(500)

    report =
      Recorder.finish(s.recorder, %{
        scenario: "approval-acknowledgment",
        model: Parlora.Providers.OpenAI.default_model(),
        mode: "replay",
        checks: checks,
        passed: Enum.all?(checks, &elem(&1, 1))
      })

    IO.puts(JSON.encode!(Map.take(report, [:scenario, :model, :checks, :passed])))
    report
  end

  defp now, do: System.monotonic_time(:millisecond)
end

[directory, audio] = System.argv()
report = BookingDesk.ApprovalLiveProbe.run(directory, audio)
unless report.passed, do: System.halt(1)
