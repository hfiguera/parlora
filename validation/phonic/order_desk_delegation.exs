# Run from examples/order_desk with an in-memory database and synthetic PCM clips.
for file <- ["memory_audio.ex", "memory_channel.ex"] do
  Code.require_file(Path.expand("../../test/support/#{file}", __DIR__))
end

defmodule Parlora.PhonicOrderDeskDelegation do
  alias Parlora.{AudioFormat, AudioFrame, Event}
  alias Parlora.TestSupport.{MemoryAudio, MemoryChannel}

  def run(directory, output) do
    :phonic = Application.fetch_env!(:order_desk, :voice_provider)
    ":memory:" = Application.fetch_env!(:order_desk, :database)
    {Parlora.Providers.Phonic, _options} = OrderDesk.Provider.selected()

    {:ok, session} =
      OrderDesk.BrowserGate.start_session(
        {MemoryChannel, observer: self()},
        "synthetic-delegation"
      )

    Process.send_after(self(), :deadline, 100_000)
    Process.send_after(self(), :tick, 10)

    state = %{
      session: session,
      channel: nil,
      ready?: false,
      directory: directory,
      output: output,
      stage: :greeting,
      text: "",
      pending: <<>>,
      sequence: 0,
      advancing?: false,
      calls: %{greeting: 0, items: 0, instructions: 0, draft: 0},
      requests: [],
      completed: 0,
      audio_bytes: 0,
      captions: [],
      failures: []
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
          | calls: Map.update!(state.calls, state.stage, &(&1 + 1)),
            requests: [%{stage: state.stage, arguments: payload.arguments} | state.requests]
        })

      {:parlora_event, %Event{source: :backend, type: :request_completed}} ->
        loop(%{state | completed: state.completed + 1})

      {:parlora_event,
       %Event{type: :transcript_delta, payload: %{speaker: :assistant, delta: text}}} ->
        loop(%{
          state
          | text: state.text <> text,
            captions: [%{stage: state.stage, text: text} | state.captions]
        })

      {:parlora_event,
       %Event{source: :provider, type: :provider_speech, payload: %{state: :idle}}} ->
        if not state.advancing? and answered?(state) do
          Process.send_after(self(), :advance, 2_000)
          loop(%{state | advancing?: true})
        else
          loop(state)
        end

      :advance ->
        case state.stage do
          :draft ->
            finish(state, :completed)

          previous ->
            stage = %{greeting: :items, items: :instructions, instructions: :draft}[previous]
            audio = File.read!(Path.join(state.directory, "#{stage}.pcm"))
            loop(%{state | stage: stage, pending: audio, text: "", advancing?: false})
        end

      :tick ->
        next = pump(state)
        Process.send_after(self(), :tick, 10)
        loop(next)

      {:parlora_event, %Event{type: :failed}} ->
        finish(%{state | failures: [:adapter_failed | state.failures]}, :failed)

      {:parlora_event, %Event{source: :session, type: :closed}} ->
        finish(state, :closed)

      :deadline ->
        finish(state, :timeout)

      _event ->
        loop(state)
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
    %{state | pending: rest, sequence: state.sequence + 1, audio_bytes: state.audio_bytes + bytes}
  end

  defp answered?(state) do
    text = String.downcase(state.text)

    case state.stage do
      :greeting ->
        String.contains?(text, "order")

      :items ->
        String.contains?(text, "desk lamp")

      :instructions ->
        String.contains?(text, "instructions") and
          Enum.any?(["no ", "none", "empty", "not "], &String.contains?(text, &1))

      :draft ->
        String.contains?(text, "draft") and String.contains?(text, "confirm")
    end
  end

  defp finish(state, reason) do
    dashboard = OrderDesk.Store.dashboard("synthetic-delegation")
    order = Enum.find(dashboard.orders, &(&1.id == "124"))

    checks = %{
      completed: reason == :completed,
      one_call_per_request: state.calls == %{greeting: 0, items: 1, instructions: 1, draft: 1},
      three_backend_completions: state.completed == 3,
      one_review_draft: match?([%{order: "124", status: "pending"}], dashboard.proposals),
      draft_has_requested_text:
        Enum.any?(dashboard.proposals, &String.contains?(&1.instructions, "reception")),
      voice_did_not_save:
        dashboard.changes == [] and order.version == 1 and order.instructions == "",
      output_audio_received: state.audio_bytes > 0,
      no_adapter_failure: state.failures == []
    }

    report = %{
      model: "phonic-1",
      synthetic_speech: true,
      channel: "in-memory PCM through actual OrderDesk/Parlora pipeline",
      result: reason,
      passed: Enum.all?(checks, &elem(&1, 1)),
      checks: checks,
      calls: state.calls,
      backend_completions: state.completed,
      audio_bytes: state.audio_bytes,
      requests: Enum.reverse(state.requests),
      captions: Enum.reverse(state.captions)
    }

    File.mkdir_p!(Path.dirname(state.output))
    File.write!(state.output, JSON.encode!(report))
    IO.puts(JSON.encode!(Map.take(report, [:passed, :result, :calls, :checks])))
    unless report.passed, do: System.halt(1)
  end
end

[directory, output] = System.argv()
Parlora.PhonicOrderDeskDelegation.run(directory, output)
