# Run from examples/order_desk with an in-memory database and synthetic PCM clips.
for file <- ["memory_audio.ex", "memory_channel.ex"] do
  Code.require_file(Path.expand("../../test/support/#{file}", __DIR__))
end

defmodule Parlora.OrderDeskInterpretationLive do
  alias Parlora.{AudioFormat, AudioFrame, Event}
  alias Parlora.TestSupport.{MemoryAudio, MemoryChannel}

  def run(directory, output) do
    ":memory:" = Application.fetch_env!(:order_desk, :database)
    Application.put_env(:order_desk, :lookup_delays, %{"123" => 8_000})

    {:ok, session} =
      OrderDesk.BrowserGate.start_session(
        {MemoryChannel, observer: self()},
        "synthetic-scheduling"
      )

    Process.send_after(self(), :deadline, 170_000)
    Process.send_after(self(), :tick, 10)

    state = %{
      session: session,
      channel: nil,
      ready?: false,
      speech: :unknown,
      last_audio_at: System.monotonic_time(:millisecond),
      directory: directory,
      output: output,
      stage: :greeting,
      text: "",
      pending: <<>>,
      sequence: 0,
      advancing?: false,
      calls: %{},
      submitted: [],
      stale_results: 0,
      correction_pending?: false,
      requests: [],
      completed: 0,
      audio_bytes: 0,
      captions: [],
      failures: [],
      answered_stage?: false,
      extra_result_replies: []
    }

    try do
      loop(state)
    after
      Parlora.close(session, :cancel)
    end
  end

  defp loop(state) do
    receive do
      {:adapter, :channel, channel} ->
        loop(%{state | channel: channel})

      {:parlora_event, %Event{source: :session, type: :ready}} ->
        {:ok, _task} = OrderDesk.BrowserServer.greet(state.session)
        loop(%{state | ready?: true})

      {:parlora_event, %Event{source: :provider, type: :delegation_requested, payload: payload}} ->
        loop(%{
          state
          | calls: Map.update(state.calls, state.stage, 1, &(&1 + 1)),
            requests: [
              %{stage: state.stage, arguments: Map.get(payload, :arguments)} | state.requests
            ]
        })

      {:parlora_event,
       %Event{source: :session, type: :task_submitted, payload: %{request: request}}} ->
        next = %{state | submitted: [request.input | state.submitted]}

        if state.stage == :lookup and request.input.order == "123" do
          Process.send_after(self(), :correct, 300)
          loop(next)
        else
          loop(next)
        end

      {:parlora_event, %Event{type: :stale_result}} ->
        loop(%{state | stale_results: state.stale_results + 1})

      :correct ->
        jobs = Parlora.status(state.session).jobs
        pending? = Enum.any?(jobs, fn {_id, job} -> job.status in [:submitted, :running] end)
        next = enter(state, :correction)
        loop(%{next | correction_pending?: pending?})

      {:parlora_event, %Event{source: :backend, type: :request_completed}} ->
        loop(%{state | completed: state.completed + 1})

      {:parlora_event,
       %Event{type: :transcript_delta, payload: %{speaker: :assistant, delta: text}}} ->
        loop(%{
          state
          | text: state.text <> text,
            captions: [%{stage: state.stage, text: text} | state.captions]
        })

      {:parlora_event, %Event{source: :provider, type: :context_submitted}} ->
        # A fresh application update can legitimately request another response.
        # Correlation-only association closures emit no context submission.
        loop(%{state | answered_stage?: false})

      {:parlora_event,
       %Event{source: :provider, type: :provider_speech, payload: %{state: speech}}} ->
        extra? =
          speech == :speaking and state.answered_stage? and
            state.stage in [:correction, :items, :draft, :refusal, :newdraft, :save]

        state =
          if extra?,
            do: %{state | extra_result_replies: [state.stage | state.extra_result_replies]},
            else: state

        state = %{state | speech: speech}

        state =
          if speech == :idle and answered?(state),
            do: %{state | answered_stage?: true},
            else: state

        if not state.advancing? and ready_to_advance?(state) do
          Process.send_after(self(), :advance, 2_000)
          loop(%{state | advancing?: true})
        else
          loop(state)
        end

      :advance ->
        if ready_to_advance?(state) do
          advance(state)
        else
          loop(%{state | advancing?: false})
        end

      :tick ->
        next = pump(state)

        next =
          if not next.advancing? and ready_to_advance?(next) do
            Process.send_after(self(), :advance, 2_000)
            %{next | advancing?: true}
          else
            next
          end

        Process.send_after(self(), :tick, 10)
        loop(next)

      {:parlora_event, %Event{type: :failed} = event} ->
        failure = %{source: event.source, payload: inspect(event.payload)}
        finish(%{state | failures: [failure | state.failures]}, :failed)

      {:parlora_event, %Event{source: :session, type: :closed}} ->
        finish(state, :closed)

      :deadline ->
        finish(state, :timeout)

      _event ->
        loop(state)
    end
  end

  defp advance(state) do
    case state.stage do
      :save ->
        finish(state, :completed)

      :newdraft ->
        dashboard = OrderDesk.Store.dashboard("synthetic-scheduling")
        [] = dashboard.changes
        {:ok, %{version: 1}} = OrderDesk.Store.order("124")
        proposal = Enum.find(dashboard.proposals, &(&1.status == "pending"))

        {:ok, %{outcome: "applied", result: result}} =
          OrderDesk.Operations.confirm(%{
            actor: "synthetic-scheduling",
            proposal: proposal.id
          })

        OrderDesk.BrowserGate.notify("synthetic-scheduling", result)
        loop(%{state | stage: :save, text: "", advancing?: false, answered_stage?: false})

      previous ->
        stage =
          %{
            greeting: :lookup,
            correction: :items,
            items: :clarify,
            clarify: :draft,
            draft: :refusal,
            refusal: :newdraft
          }[previous]

        loop(enter(state, stage))
    end
  end

  defp pump(%{channel: nil} = state), do: state
  defp pump(%{ready?: false} = state), do: state

  defp pump(state) do
    size = AudioFormat.bytes_for_ms(%AudioFormat{}, 10)
    count = min(byte_size(state.pending), size)
    <<chunk::binary-size(^count), rest::binary>> = state.pending

    frame =
      AudioFrame.pcm(chunk <> :binary.copy(<<0>>, size - count), "synthetic", state.sequence)

    :ok = MemoryAudio.audio(state.channel, frame)
    frames = MemoryAudio.drain(state.channel)
    bytes = Enum.reduce(frames, 0, &(byte_size(&1.data) + &2))

    %{
      state
      | pending: rest,
        sequence: state.sequence + 1,
        audio_bytes: state.audio_bytes + bytes,
        last_audio_at:
          if(Enum.any?(frames, &audible?/1),
            do: System.monotonic_time(:millisecond),
            else: state.last_audio_at
          )
    }
  end

  defp audible?(frame) do
    for <<sample::little-signed-16 <- frame.data>>, reduce: false do
      loud? -> loud? or abs(sample) > 256
    end
  end

  defp enter(state, stage) do
    IO.puts(JSON.encode!(%{stage: stage, event: "synthetic_input"}))

    %{
      state
      | stage: stage,
        pending: File.read!(Path.join(state.directory, "#{stage}.pcm")),
        text: "",
        answered_stage?: false,
        advancing?: false
    }
  end

  defp ready_to_advance?(state) do
    state.speech != :speaking and
      System.monotonic_time(:millisecond) - state.last_audio_at >= 600 and answered?(state)
  end

  defp answered?(state) do
    text = String.downcase(state.text)
    proposals = OrderDesk.Store.dashboard("synthetic-scheduling").proposals

    state.pending == <<>> and
      case state.stage do
        :greeting ->
          String.contains?(text, "order")

        :lookup ->
          false

        :correction ->
          String.contains?(text, "out for delivery")

        :items ->
          String.contains?(text, "desk lamp")

        :clarify ->
          proposals == [] and
            String.contains?(text, ["instruction", "wording"]) and
            String.contains?(text, ["?", "tell", "provide", "state", "say", "what", "would you"])

        :draft ->
          Enum.any?(proposals, &(&1.status == "pending")) and text != ""

        :refusal ->
          Enum.any?(proposals, &(&1.status == "rejected")) and text != ""

        :newdraft ->
          Enum.any?(
            proposals,
            &(&1.status == "pending" and String.contains?(&1.instructions, "neighbor"))
          ) and text != ""

        :save ->
          Enum.any?(["saved", "updated"], &String.contains?(text, &1)) and
            String.contains?(text, "neighbor")
      end
  end

  defp finish(state, reason) do
    dashboard = OrderDesk.Store.dashboard("synthetic-scheduling")
    order = Enum.find(dashboard.orders, &(&1.id == "124"))

    operations = Enum.reverse(state.submitted)
    corrections = Enum.filter(operations, &(&1.operation == "status"))

    checks = %{
      completed: reason == :completed,
      correction_during_pending_work: state.correction_pending?,
      corrected_order: Enum.map(corrections, & &1.order) == ["123", "124"],
      stale_original_discarded: state.stale_results > 0,
      no_duplicate_backend_operations: length(operations) == 6,
      followup_items: Enum.any?(operations, &(&1.operation == "items" and &1.order == "124")),
      clarified_delivery: Enum.count(operations, &(&1.operation == "delivery")) == 2,
      refusal_executed: Enum.any?(operations, &(&1.operation == "refuse")),
      one_explicit_save:
        length(dashboard.changes) == 1 and order.version == 2 and
          String.contains?(order.instructions, "neighbor"),
      rejected_draft: Enum.count(dashboard.proposals, &(&1.status == "rejected")) == 1,
      output_audio_received: state.audio_bytes > 0,
      no_adapter_failure: state.failures == []
    }

    checks =
      if System.get_env("ORDER_DESK_ASSERT_SINGLE_REPLY") == "1",
        do:
          Map.put(
            checks,
            :no_reply_after_answer_without_new_context,
            state.extra_result_replies == []
          ),
        else: checks

    report = %{
      provider: Application.fetch_env!(:order_desk, :voice_provider),
      synthetic_speech: true,
      channel: "in-memory PCM through actual OrderDesk/Parlora pipeline",
      result: reason,
      final_stage: state.stage,
      final_speech: state.speech,
      passed: Enum.all?(checks, &elem(&1, 1)),
      checks: checks,
      calls: state.calls,
      backend_completions: state.completed,
      audio_bytes: state.audio_bytes,
      operations: operations,
      interpretation: OrderDesk.Interpretation.stats(),
      failures: state.failures,
      extra_result_replies: Enum.reverse(state.extra_result_replies),
      final_status:
        inspect(Parlora.status(state.session), limit: :infinity, printable_limit: :infinity),
      final_snapshot:
        inspect(Parlora.snapshot(state.session), limit: :infinity, printable_limit: :infinity),
      evidence: OrderDesk.Interpretation.evidence(),
      requests: Enum.reverse(state.requests),
      captions: Enum.reverse(state.captions)
    }

    File.mkdir_p!(Path.dirname(state.output))
    File.write!(state.output, JSON.encode!(report))
    IO.puts(JSON.encode!(Map.take(report, [:passed, :result, :calls, :checks])))
    report
  end
end

unless System.get_env("ORDER_DESK_LIVE_IMPORT") == "1" do
  [directory, output] = System.argv()
  report = Parlora.OrderDeskInterpretationLive.run(directory, output)
  unless report.passed, do: System.halt(1)
end
