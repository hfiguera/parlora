defmodule Parlora.Validation.AudioSocket do
  @moduledoc false
  @behaviour WebSock
  alias Parlora.{AdapterInit, AudioFormat, AudioPipeline, Event, ID, Limits}
  alias Parlora.Channels.Browser
  alias Parlora.Validation.PlayoutTimeline
  alias Parlora.TestSupport.AudioBenchmark.{Scenarios, Source}

  @impl true
  def init(options) do
    init = %AdapterInit{
      session_id: ID.new(),
      adapter_id: "browser-benchmark",
      generation: 0,
      audio_format: %AudioFormat{},
      limits: %Limits{},
      event_sink: self()
    }

    {:ok, source} = Source.start_link(init, :real)

    {:ok, channel} =
      Browser.start_link(init, Keyword.put(options[:channel_options] || [], :signaling, self()))

    owner = self()
    Agent.update(Parlora.Validation.AudioConnections, &MapSet.put(&1, owner))
    Process.send_after(self(), :timeout, options[:duration_ms] + 30_000)

    {:ok,
     %{
       init: init,
       source: source,
       channel: channel,
       pipeline: nil,
       input: nil,
       options: options,
       trace: PlayoutTimeline.open(options[:trace_directory], init),
       running: false
     }}
  end

  @impl true
  def handle_in({json, [opcode: :text]}, state) do
    message = Jason.decode!(json)
    dispatch(message, state)
  end

  defp dispatch(%{"type" => type} = signal, state) when type in ["offer", "candidate"] do
    :ok = Browser.signal(state.channel, signal)
    {:ok, state}
  end

  defp dispatch(%{"type" => "run"}, %{running: false} = state) do
    scenario =
      if state.options[:arrival_schedule] do
        Scenarios.recorded(state.options[:arrival_schedule], state.options[:reference_pcm])
      else
        Scenarios.build(
          state.options[:scenario],
          42,
          state.options[:duration_ms],
          state.options[:reference_pcm]
        )
      end

    start = System.monotonic_time(:millisecond)
    PlayoutTimeline.mark(state.trace, :run)
    for {at, pcm} <- scenario.events, do: Process.send_after(self(), {:feed, pcm}, div(at, 1_000))
    finish = Scenarios.timeline(scenario).causal_finish_us
    Process.send_after(self(), :finished, div(finish, 1_000) + 1_500)
    push(%{type: "started", server_ms: start, schedule: scenario.name}, %{state | running: true})
  end

  defp dispatch(%{"type" => "interrupt"}, state) do
    before = Browser.observations(state.channel)
    :ok = AudioPipeline.control(state.pipeline, "stop", {:suppress_output, true})

    {clear_us, :ok} =
      :timer.tc(fn -> AudioPipeline.control(state.pipeline, "clear", {:clear_output, :next}) end)

    old =
      Parlora.AudioFrame.pcm(:binary.copy(<<1, 0>>, 240), "old", 0, playback_epoch: before.epoch)

    rejected = match?({:error, _}, Browser.write_audio(state.channel, old))
    Process.send_after(self(), :resume, 300)
    push(%{type: "interrupted", clear_us: clear_us, old_epoch_rejected: rejected}, state)
  end

  defp dispatch(%{"type" => "stats"}, state),
    do: push(%{type: "stats", data: Browser.observations(state.channel)}, state)

  defp dispatch(%{"type" => "disconnect"}, state), do: {:stop, :normal, 1000, state}
  defp dispatch(_message, state), do: {:ok, state}

  @impl true
  def handle_info({:parlora_browser, _channel, :attached}, state), do: {:ok, state}

  def handle_info({:parlora_browser, _channel, {:signal, message}}, state),
    do: push(message, state)

  def handle_info({:parlora_event, %Event{type: :ready}}, state) do
    {:ok, pipeline} =
      state.options[:output_pipeline].start_link(
        init: state.init,
        direction: :output,
        source: {Source, state.source},
        destination: {Browser, state.channel},
        output_pacing: :channel
      )

    {:ok, input} =
      AudioPipeline.start_link(
        init: state.init,
        direction: :input,
        source: {Browser, state.channel},
        destination: {Source, state.source}
      )

    push(%{type: "ready"}, %{state | pipeline: pipeline, input: input})
  end

  def handle_info({:feed, pcm}, state) do
    case Source.push(state.source, pcm, System.monotonic_time(:microsecond)) do
      :ok -> {:ok, state}
      {:error, error} -> push(%{type: "failure", code: error.code}, state)
    end
  end

  def handle_info(:resume, state) do
    :ok = AudioPipeline.control(state.pipeline, "resume", {:suppress_output, false})
    push(%{type: "resumed"}, state)
  end

  def handle_info(:finished, state),
    do: push(%{type: "finished", data: Browser.observations(state.channel)}, state)

  def handle_info(:timeout, state), do: {:stop, :normal, 1000, state}

  def handle_info({:parlora_event, %Event{type: :audio_discontinuity, payload: payload}}, state),
    do: push(%{type: "failure", data: payload}, state)

  def handle_info({:parlora_event, %Event{type: :audio_observed, payload: payload}}, state),
    do: push(%{type: "observation", data: payload}, state)

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, state) do
    for pid <- [state.pipeline, state.input, state.channel, state.source],
        is_pid(pid),
        Process.alive?(pid),
        do: GenServer.stop(pid, :normal, 5_000)

    owner = self()
    PlayoutTimeline.close(state.trace)
    Agent.update(Parlora.Validation.AudioConnections, &MapSet.delete(&1, owner))
    :ok
  end

  defp push(message, state), do: {:push, {:text, Jason.encode!(message)}, state}
end
