defmodule Parlora.Telemetry do
  @moduledoc """
  Telemetry event names for observing Parlora sessions.

  Parlora emits measurements; your application configures metric reporters,
  tracing exporters and logging. No monitoring service is required.

  Use `events/0` with `:telemetry.attach_many/4` to observe operation lifecycles and
  operational events. Audio event names are selected separately. See
  [Metrics, traces and logs](observability.html) for a complete handler example,
  event definitions, units and timing boundaries.
  """
  alias Parlora.ID

  @operations ~w(session startup shutdown policy backend_queue backend delivery recovery interruption)a
  @events ~w(failed policy_failed policy_rejected admission_rejected adapter_down disconnected
    cancellation_requested cancellation_rejected cancellation_unconfirmed delegation_cancelled
    update_applied update_rejected update_uncertain delegation_associated
    stale_result result_delivery request_uncertain output_recovery_requested output_recovered
    output_interrupted playback_observed audio_discontinuity audio_observed usage_updated usage_final)a
  @categories ~w(ok ready started completed failed cancelled uncertain unknown unconfirmed rejected
    accepted stale not_applicable superseded timeout error closed reconnected interrupted
    awaiting_interpretation awaiting_provider queued handed_off cleared estimated_playback
    device_reported_playback source_queue_empty source_resumed startup_capture_discard
    output_overflow output_stale deadline pressure buffering_disabled queue_ready other
    pcmu pcm channel provider backend input_pipeline output_pipeline browser_pcm browser_rtp
    device_reported estimated local_observation transport_handoff server_reported)a
  @identity ~w(session_id operation_id parent_operation_id request_id task_id delegation_id
    command_id adapter_id)a

  @doc """
  Returns operation start/stop names and `[:parlora, :runtime, :event]`.

  This lists names without attaching a handler. It excludes audio measurements
  and the older `[:parlora, :event]` counter.
  """
  @spec events() :: [[atom()]]
  def events do
    for(operation <- @operations, stage <- [:start, :stop], do: [:parlora, operation, stage]) ++
      [[:parlora, :runtime, :event]]
  end

  @doc false
  def start(operation, metadata) when operation in @operations do
    token = %{
      operation: operation,
      started: System.monotonic_time(),
      metadata: metadata |> safe_metadata() |> Map.put(:operation_id, ID.new())
    }

    :telemetry.execute([:parlora, operation, :start], clock(token.started), token.metadata)
    token
  end

  @doc false
  def stop(nil, _outcome), do: :ok

  def stop(token, outcome) do
    now = System.monotonic_time()
    measurements = Map.merge(clock(now), %{duration: max(0, now - token.started), count: 1})
    metadata = Map.put(token.metadata, :outcome, category(outcome))
    :telemetry.execute([:parlora, token.operation, :stop], measurements, metadata)
  end

  @doc false
  def finish(record, key, outcome) do
    stop(Map.get(record, key), outcome)
    Map.delete(record, key)
  end

  @doc false
  def close_job(job) do
    job
    |> finish(:telemetry_queue, :closed)
    |> finish(:telemetry_backend, :uncertain)
    |> finish(:telemetry_delivery, :closed)
  end

  @doc false
  def session_metadata(options, id) do
    Map.new([:channel, :provider, :backend], fn role ->
      {module, _options} = Keyword.fetch!(options, role)
      {role, Atom.to_string(module)}
    end)
    |> Map.put(:session_id, id)
  end

  @doc false
  def request(state, request) do
    Map.merge(
      state.startup.telemetry_session.metadata,
      Map.take(request, [:task_id, :task_revision, :provider_generation, :delegation_id])
    )
    |> Map.put(:request_id, request.id)
    |> Map.put(:parent_operation_id, state.startup.telemetry_session.metadata.operation_id)
  end

  @doc false
  def event(%{type: type} = event) when type in @events and is_map(event.payload) do
    payload = event.payload

    metadata =
      Map.take(event, [
        :session_id,
        :adapter_id,
        :generation,
        :source,
        :type,
        :command_id,
        :request_id
      ])
      |> Map.merge(Map.take(payload, [:task_id, :task_revision, :provider_generation]))
      |> safe_metadata()

    metadata =
      Enum.reduce(
        [:stage, :cause, :boundary, :evidence, :role, :recovery_release_reason],
        metadata,
        fn key, acc ->
          if Map.has_key?(payload, key), do: Map.put(acc, key, category(payload[key])), else: acc
        end
      )

    measurements =
      payload
      |> Map.take([
        :duration_us,
        :inserted_silence_us,
        :source_unavailable_us,
        :recovery_wait_us,
        :dropped_bytes,
        :dropped_frames,
        :dropped_duration_us,
        :seconds
      ])
      |> Map.filter(fn {_key, value} -> is_number(value) and value >= 0 end)
      |> Map.put(:count, 1)

    :telemetry.execute([:parlora, :runtime, :event], measurements, metadata)
  end

  def event(_event), do: :ok

  defp clock(monotonic),
    do: %{system_time: System.system_time(), monotonic_time: monotonic}

  defp safe_metadata(metadata), do: Map.filter(metadata, &safe_entry?/1)

  defp safe_entry?({key, value}) when key in @identity,
    do: is_binary(value) and byte_size(value) <= 256

  defp safe_entry?({key, value}) when key in [:task_revision, :provider_generation, :generation],
    do: is_integer(value)

  defp safe_entry?({key, value}) when key in [:channel, :provider, :backend],
    do: is_binary(value) and byte_size(value) <= 256

  defp safe_entry?({:source, value}), do: value in [:session, :provider, :backend, :channel]
  defp safe_entry?({:type, value}), do: value in @events
  defp safe_entry?(_entry), do: false

  defp category(value) when value in @categories, do: value
  defp category(_value), do: :other
end
