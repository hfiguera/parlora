# Opt-in diagnostic launch for examples/order_desk. No raw audio or credentials.
# Bounded ETS rings and a single periodic writer keep I/O off media processes.
defmodule BrowserAudioTrace do
  use GenServer
  @events 8192
  @gaps 16

  def start_link(directory), do: GenServer.start_link(__MODULE__, directory)

  def record(name, measurements, metadata, table) do
    if metadata[:direction] in [nil, :output] and is_binary(metadata[:session_id]) and
         is_integer(measurements[:at_us]) do
      index = :ets.update_counter(table, :events, {2, 1}, {:events, 0})

      event = %{
        index: index,
        kind: List.last(name),
        measurements: measurements,
        metadata: metadata
      }

      :ets.insert(table, {{:event, rem(index, @events)}, event})

      if List.last(name) == :playout_gap and measurements.cause != :source_queue_empty do
        gap = :ets.update_counter(table, :gaps, {2, 1}, {:gaps, 0})
        :ets.insert(table, {{:gap, rem(gap, @gaps)}, Map.put(event, :report_index, gap)})
      end
    end
  end

  def init(directory) do
    File.mkdir_p!(directory)
    table = :ets.new(__MODULE__, [:set, :public, write_concurrency: true])
    id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach_many(
        id,
        [
          [:parlora, :provider, :audio_received],
          [:parlora, :provider, :audio_read],
          [:parlora, :audio, :frame],
          [:parlora, :audio, :tick],
          [:parlora, :audio, :recovery_pressure],
          [:parlora, :audio, :playout],
          [:parlora, :audio, :playout_gap]
        ],
        &__MODULE__.record/4,
        table
      )

    Process.send_after(self(), :flush, 250)
    {:ok, %{table: table, handler: id, directory: directory, written: 0}}
  end

  def handle_info(:flush, state) do
    entries = :ets.tab2list(state.table)
    events = for {{:event, _}, event} <- entries, do: event
    gaps = for {{:gap, _}, gap} <- entries, gap.report_index > state.written, do: gap

    written =
      Enum.reduce(Enum.sort_by(gaps, & &1.report_index), state.written, fn gap, _written ->
        start = gap.measurements.started_at_us - 1_000_000
        stop = gap.measurements.at_us + 100_000

        selected =
          events
          |> Enum.filter(fn event ->
            event.metadata.session_id == gap.metadata.session_id and
              event.measurements.at_us >= start and event.measurements.at_us <= stop
          end)
          |> Enum.sort_by(& &1.measurements.at_us)

        report = %{
          provenance:
            "Opt-in server timing trace; numeric media observations, no raw audio. Bounded rolling history, not a speaker recording.",
          event_capacity: @events,
          report_capacity: @gaps,
          gap: gap,
          events: selected,
          earliest_retained_at_us:
            events |> Enum.map(& &1.measurements.at_us) |> Enum.min(fn -> nil end)
        }

        path = Path.join(state.directory, "gap-#{rem(gap.report_index, @gaps)}.json")
        File.write!(path <> ".tmp", Jason.encode!(report, pretty: true) <> "\n")
        File.rename!(path <> ".tmp", path)
        gap.report_index
      end)

    Process.send_after(self(), :flush, 250)
    {:noreply, %{state | written: written}}
  end

  def terminate(_reason, state), do: :telemetry.detach(state.handler)
end
