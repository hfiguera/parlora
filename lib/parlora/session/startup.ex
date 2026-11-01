defmodule Parlora.Session.Startup do
  @moduledoc false
  alias Parlora.{AdapterOwner, AudioPipeline, Error, ID, SessionSupervisor, Telemetry}
  alias Parlora.Session.{Shutdown, State}

  def start(state) do
    Process.send_after(self(), :startup_timeout, state.limits.startup_timeout_ms)
    deadline = System.monotonic_time(:microsecond) + state.limits.startup_timeout_ms * 1_000
    start_adapter(%{state | startup: %{state.startup | deadline_us: deadline}}, :channel)
  end

  def adapter_started(state, role, module, pid) do
    state = %{
      state
      | adapters: Map.put(state.adapters, role, {module, pid}),
        startup: %{state.startup | pending: nil}
    }

    case role do
      :channel -> start_adapter(state, :provider)
      :provider -> start_adapter(state, :backend)
      :backend -> maybe_start_audio(state)
    end
  end

  def ready(state, role, capabilities) do
    maybe_start_audio(%{state | ready: Map.put(state.ready, role, capabilities)})
  end

  def pipeline_ready(state, pid) do
    pending = MapSet.delete(state.startup.pending_pipelines, pid)
    state = %{state | startup: %{state.startup | pending_pipelines: pending}}
    if MapSet.size(pending) == 0, do: complete_startup(state), else: state
  end

  defp start_adapter(state, role) do
    if System.monotonic_time(:microsecond) < state.startup.deadline_us,
      do: start_adapter_owner(state, role),
      else: failed(state, :timeout)
  end

  defp start_adapter_owner(state, role) do
    {module, options} = Keyword.fetch!(state.options, role)
    options = if role == :provider, do: provider_options(options, state.options), else: options

    init = %{
      state.init
      | adapter_id: ID.new(),
        audio_format: if(role == :backend, do: nil, else: state.init.audio_format)
    }

    deadline = state.startup.deadline_us

    spec = %{
      id: init.adapter_id,
      start: {AdapterOwner, :start_link, [fn -> {module, init, options, deadline} end]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(SessionSupervisor.via(state.id, :adapters), spec) do
      {:ok, owner, watcher} ->
        ref = Process.monitor(owner)

        %{
          state
          | startup: %{
              state.startup
              | pending: %{role: role, owner: owner, module: module, watcher: watcher},
                owners: Map.put(state.startup.owners, role, %{owner: owner, watcher: watcher})
            },
            monitors: Map.put(state.monitors, ref, role),
            options: Keyword.put(state.options, role, {init, []})
        }

      {:error, _reason} ->
        failed(state, :adapter_failed)
    end
  end

  def failed(state, reason) do
    message =
      if reason == :timeout,
        do: "Session readiness deadline expired",
        else: "Adapter startup failed"

    Telemetry.stop(
      state.startup.telemetry_startup,
      if(reason == :timeout, do: :timeout, else: :failed)
    )

    state = %{state | startup: %{state.startup | telemetry_startup: nil}}
    State.emit(state, :failed, %{error: Error.new(reason, message)})
    Shutdown.begin(state, :cancel)
  end

  defp provider_options(options, session_options) do
    Keyword.merge(Keyword.take(session_options, [:instructions, :history]), options)
  end

  defp start_audio(state) do
    state = %{state | startup: %{state.startup | pipeline_token: make_ref()}}

    with :ok <- validate_capabilities(state),
         {:ok, input} <-
           start_pipeline(state, :input, state.adapters.channel, state.adapters.provider),
         {:ok, output} <-
           start_pipeline(state, :output, state.adapters.provider, state.adapters.channel) do
      monitors =
        state.monitors
        |> Map.put(Process.monitor(input), :input_pipeline)
        |> Map.put(Process.monitor(output), :output_pipeline)

      %{
        state
        | input_pipeline: input,
          output_pipeline: output,
          startup: %{state.startup | pending_pipelines: MapSet.new([input, output])},
          monitors: monitors
      }
    else
      {:error, error} ->
        State.emit(state, :failed, %{error: error})
        Shutdown.begin(state, :cancel)
    end
  end

  defp maybe_start_audio(
         %{status: :starting, input_pipeline: nil, adapters: adapters, ready: ready} = state
       )
       when map_size(adapters) == 3 and map_size(ready) == 3 do
    if System.monotonic_time(:microsecond) < state.startup.deadline_us,
      do: start_audio(state),
      else: failed(state, :timeout)
  end

  defp maybe_start_audio(state), do: state

  defp complete_startup(state) do
    if System.monotonic_time(:microsecond) < state.startup.deadline_us do
      Telemetry.stop(state.startup.telemetry_startup, :ready)
      State.emit(state, :ready, %{capabilities: state.ready})

      Enum.each([state.input_pipeline, state.output_pipeline], fn pid ->
        send(pid, {:activate_pipeline, state.startup.pipeline_token})
      end)

      %{state | status: :ready, startup: %{state.startup | telemetry_startup: nil}}
    else
      failed(state, :timeout)
    end
  end

  defp validate_capabilities(state) do
    format = state.init.audio_format
    channel = state.ready.channel
    provider = state.ready.provider

    if format in channel.input_formats and format in channel.output_formats and
         channel.output_pacing in [:pipeline, :channel] and
         format in provider.audio_formats and channel.full_duplex? and provider.full_duplex? and
         :client in provider.delegation_modes and :speakable in provider.context_update_kinds do
      :ok
    else
      Error.tuple(
        :unsupported,
        "Adapters do not support the required full-duplex client-delegation path"
      )
    end
  end

  defp start_pipeline(state, direction, source, destination) do
    options = [
      init: state.init,
      startup_owner: self(),
      startup_token: state.startup.pipeline_token,
      direction: direction,
      source: source,
      destination: destination,
      health_counters: state.health.audio,
      output_pacing: state.ready.channel.output_pacing
    ]

    spec = %{
      id: direction,
      start: {AudioPipeline, :start_link, [options]},
      restart: :temporary,
      shutdown: :brutal_kill
    }

    DynamicSupervisor.start_child(SessionSupervisor.via(state.id, :adapters), spec)
  end
end
