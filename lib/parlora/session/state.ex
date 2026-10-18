defmodule Parlora.Session.State do
  @moduledoc false
  alias Parlora.{AdapterInit, AudioFormat, ContextSnapshot, Event}
  alias Parlora.Session.{Commands, Health}

  defstruct [
    :id,
    :init,
    :limits,
    :options,
    :policy,
    :policy_task,
    :policy_trigger,
    :output_pipeline,
    :input_pipeline,
    :shutdown_timer,
    :health,
    :output_recovery,
    status: :starting,
    policy_failures: 0,
    context_resolved?: true,
    adapters: %{},
    startup: %{
      deadline_us: nil,
      pending: nil,
      owners: %{},
      pipeline_token: nil,
      pending_pipelines: MapSet.new(),
      cleanup: MapSet.new(),
      commands: Commands.new()
    },
    ready: %{},
    monitors: %{},
    subscribers: %{},
    context: %ContextSnapshot{},
    jobs: %{},
    context_waits: %{},
    playback: %{},
    provider_activity: :unknown,
    provider_speech: :unknown,
    clarifications: MapSet.new(),
    finalization: false,
    usage: nil,
    cancellations: %{},
    closing_adapters: MapSet.new()
  ]

  def new(options) do
    id = Keyword.fetch!(options, :id)
    limits = Keyword.fetch!(options, :limits)

    %__MODULE__{
      id: id,
      health: Health.new(limits.max_records),
      limits: limits,
      options: options,
      policy: Keyword.fetch!(options, :context_policy),
      init: %AdapterInit{
        session_id: id,
        adapter_id: id,
        generation: 0,
        event_sink: self(),
        audio_format: Keyword.get(options, :audio_format, %AudioFormat{}),
        limits: limits
      },
      context: %ContextSnapshot{
        session_id: id,
        provider_generation: 0,
        application_context: Keyword.get(options, :context, %{})
      }
    }
  end

  def emit(state, type, payload \\ %{}, fields \\ []) do
    Event.emit(%{state.init | event_sink: self()}, :session, type, payload, fields)
  end

  def broadcast(state, event) do
    Enum.reduce(state.subscribers, state, fn {pid, monitor}, acc ->
      case Process.info(pid, :message_queue_len) do
        {:message_queue_len, count} when count < state.limits.max_subscriber_queue ->
          send(pid, {:parlora_event, event})
          acc

        _unavailable_or_overloaded ->
          Process.demonitor(monitor, [:flush])
          send(pid, {:parlora_unsubscribed, state.id, :slow_consumer})
          %{acc | subscribers: Map.delete(acc.subscribers, pid)}
      end
    end)
  end

  def revise(state, context),
    do: %{state | context: %{context | revision: state.context.revision + 1}}

  def delivery_error_stage(state, request, error) do
    cond do
      error.details[:execution] == :never_submitted and not current_delivery?(state, request) ->
        :stale

      error.code == :timeout or error.details[:outcome] == :unknown ->
        :unknown

      true ->
        :rejected
    end
  end

  def current_delivery?(state, request),
    do: current_result?(state, request) and not cancelled_result?(state, request)

  def cancelled_result?(state, request) do
    case state.context.pending_delegations[request.delegation_id] do
      %{status: :cancelled, task_revision: revision} -> request.task_revision <= revision
      %{status: :cancelled} -> true
      _active -> false
    end
  end

  def current_result?(state, result) do
    case state.context.tasks[result.task_id] do
      %{revision: revision} ->
        revision == result.task_revision and
          result.provider_generation == state.context.provider_generation

      nil ->
        false
    end
  end
end
