defmodule ParloraObserver.Traces do
  @moduledoc "A bounded trace bridge installed by the development host."
  use GenServer
  @handler "parlora-observer-traces"
  @max_queue 256
  @max_spans 256

  def start_link(_options), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  # Telemetry callbacks run on the audio/session process: no export or span work here.
  def handle_event(name, measurements, metadata, {pid, credits}) do
    if :atomics.add_get(credits, 1, 1) <= @max_queue do
      send(pid, {:observation, name, measurements, metadata})
    else
      :atomics.sub(credits, 1, 1)
      :atomics.add(credits, 2, 1)
    end

    :ok
  end

  @impl true
  def init([]) do
    Process.flag(:trap_exit, true)
    # A killed worker cannot run terminate/2; replace only our own stale handler.
    :telemetry.detach(@handler)
    credits = :atomics.new(2, [])

    :ok =
      :telemetry.attach_many(
        @handler,
        Parlora.Telemetry.events(),
        &__MODULE__.handle_event/4,
        {self(), credits}
      )

    Process.send_after(self(), :expire, 60_000)

    {:ok,
     %{
       credits: credits,
       spans: %{},
       contexts: %{},
       tracer: :opentelemetry.get_tracer(:parlora_observer)
     }}
  end

  @impl true
  def handle_info({:observation, _, _, _} = observation, state) do
    :atomics.sub(state.credits, 1, 1)
    handle_observation(observation, state)
  end

  def handle_info(:expire, state) do
    now = System.monotonic_time(:millisecond)
    expired = for {id, entry} <- state.spans, entry.expires_at <= now, do: id

    Enum.each(expired, fn id ->
      span = state.spans[id].span
      :otel_span.set_attribute(span, "parlora.outcome", "diagnostic_expired")
      :otel_span.end_span(span)
    end)

    Process.send_after(self(), :expire, 60_000)

    {:noreply,
     %{state | spans: Map.drop(state.spans, expired), contexts: Map.drop(state.contexts, expired)}}
  end

  defp handle_observation(
         {:observation, [:parlora, operation, :start], measurements, metadata},
         state
       ) do
    if map_size(state.spans) < @max_spans do
      parent = Map.get(state.contexts, metadata[:parent_operation_id], :otel_ctx.new())

      span =
        :otel_tracer.start_span(parent, state.tracer, "parlora.#{operation}", %{
          start_time: timestamp(measurements.monotonic_time),
          attributes: attributes(metadata)
        })

      context = :otel_tracer.set_current_span(parent, span)

      entry = %{
        span: span,
        operation: operation,
        session: metadata.session_id,
        expires_at: System.monotonic_time(:millisecond) + 300_000
      }

      {:noreply,
       %{
         state
         | spans: Map.put(state.spans, metadata.operation_id, entry),
           contexts: Map.put(state.contexts, metadata.operation_id, context)
       }}
    else
      {:noreply, state}
    end
  end

  defp handle_observation(
         {:observation, [:parlora, _operation, :stop], measurements, metadata},
         state
       ) do
    case Map.pop(state.spans, metadata.operation_id) do
      {nil, _spans} ->
        {:noreply, state}

      {entry, spans} ->
        :otel_span.set_attribute(entry.span, "parlora.outcome", Atom.to_string(metadata.outcome))

        if metadata.outcome in [:error, :failed, :timeout],
          do: :otel_span.set_status(entry.span, :error, Atom.to_string(metadata.outcome))

        :otel_span.end_span(entry.span, timestamp(measurements.monotonic_time))

        {:noreply,
         %{state | spans: spans, contexts: Map.delete(state.contexts, metadata.operation_id)}}
    end
  end

  defp handle_observation(
         {:observation, [:parlora, :runtime, :event], _measurements, metadata},
         state
       ) do
    Enum.each(state.spans, fn {_id, entry} ->
      if entry.operation == :session and entry.session == metadata.session_id,
        do: :otel_span.add_event(entry.span, "parlora.#{metadata.type}", attributes(metadata))
    end)

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    :telemetry.detach(@handler)
    Enum.each(state.spans, fn {_id, entry} -> :otel_span.end_span(entry.span) end)
  end

  defp attributes(metadata),
    do:
      Map.new(metadata, fn {key, value} ->
        value = if is_atom(value), do: Atom.to_string(value), else: value
        {"parlora.#{key}", value}
      end)

  # OTel Erlang timestamps use monotonic native units; the SDK supplies the wall-clock offset.
  defp timestamp(monotonic), do: monotonic
end
