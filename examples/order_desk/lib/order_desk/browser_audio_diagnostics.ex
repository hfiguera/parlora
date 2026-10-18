defmodule OrderDesk.BrowserAudioDiagnostics do
  @moduledoc "Opt-in, bounded numeric browser audio traces; no PCM, captions or credentials."
  use GenServer

  @events [
    [:parlora, :provider, :audio_received],
    [:parlora, :provider, :audio_read],
    [:parlora, :audio, :tick],
    [:parlora, :audio, :playout]
  ]
  @measurements [
    :bytes,
    :duration_us,
    :queue_before_bytes,
    :queue_bytes,
    :dropped_bytes,
    :work_us,
    :late_us,
    :pending_frames,
    :blocked,
    :delay_ms,
    :source_bytes,
    :source_peak,
    :source_position_bytes,
    :epoch,
    :silence_bytes,
    :padding_bytes,
    :staged_bytes,
    :playback_buffer_ms,
    :playback_target_ms,
    :recovery_cap_us,
    :recovering,
    :quiet_refill,
    :quiet_refills,
    :starvations
  ]
  @gap_measurements [
    :gap_id,
    :epoch,
    :duration_us,
    :inserted_silence_us,
    :silence_bytes,
    :started_at_us,
    :source_returned_at_us,
    :source_return_queue_bytes,
    :resume_queue_bytes,
    :source_unavailable_us,
    :recovery_wait_us,
    :recovery_target_us,
    :peak_before,
    :peak_after,
    :packets
  ]

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  def attach(session, actor) do
    %{session_id: id} = Parlora.snapshot(session)
    :ok = Parlora.subscribe(session, Process.whereis(__MODULE__))
    GenServer.call(__MODULE__, {:attach, id, session, actor})
  end

  def snapshot(actor, trace? \\ true, id \\ nil),
    do: GenServer.call(__MODULE__, {:snapshot, actor, trace?, id})

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    routes = :ets.new(__MODULE__, [:named_table, :public, read_concurrency: true])
    # A killed collector cannot run terminate/2; replace its stale handler on restart.
    :telemetry.detach(__MODULE__)
    :ok = :telemetry.attach_many(__MODULE__, @events, &__MODULE__.record/4, routes)
    {:ok, %{calls: %{}, routes: routes, limit: Keyword.get(options, :max_events, 100_000)}}
  end

  # Run in the emitting process: bounded ETS writes avoid one mailbox message per audio frame.
  def record(event, measurements, metadata, routes) do
    if metadata[:direction] != :input do
      case :ets.lookup(routes, metadata[:session_id]) do
        [{_id, table, origin, limit}] ->
          index = :ets.update_counter(table, :count, 1)

          if index <= limit do
            at = measurements[:at_us] || System.monotonic_time(:microsecond)

            metrics =
              measurements |> Map.take(@measurements) |> Map.filter(fn {_, v} -> is_number(v) end)

            row = %{
              at_us: at - origin,
              recorded_at_us: System.monotonic_time(:microsecond) - origin,
              kind: List.last(event),
              metrics: metrics
            }

            :ets.insert(table, {index, row})
          end

        [] ->
          :ok
      end
    end
  rescue
    # A session or collector can finish concurrently with a telemetry callback.
    ArgumentError -> :ok
  end

  @impl true
  def handle_call({:attach, id, pid, actor}, _from, state) do
    # Four admission slots plus four recent completed calls; never evict an active trace.
    retained =
      state.calls
      |> Enum.filter(fn {_, c} -> c.closed end)
      |> Enum.sort_by(fn {_, c} -> c.origin end, :desc)
      |> Enum.take(3)
      |> Map.new()

    active = Map.reject(state.calls, fn {_, c} -> c.closed end)
    keep = Map.merge(retained, active)
    for {old_id, call} <- state.calls, not Map.has_key?(keep, old_id), do: :ets.delete(call.table)
    table = :ets.new(:browser_audio_trace, [:ordered_set, :public, write_concurrency: true])
    :ets.insert(table, {:count, 0})
    origin = System.monotonic_time(:microsecond)
    Process.monitor(pid)
    :ets.insert(state.routes, {id, table, origin, state.limit})

    call = %{
      pid: pid,
      actor: actor,
      origin: origin,
      table: table,
      closed: false,
      gaps: [],
      gap_events_seen: 0
    }

    {:reply, :ok, %{state | calls: Map.put(keep, id, call)}}
  end

  def handle_call({:snapshot, actor, trace?, wanted_id}, _from, state) do
    calls =
      for {id, c} <- state.calls, c.actor == actor and (wanted_id == nil or wanted_id == id) do
        count = :ets.lookup_element(c.table, :count, 2)

        rows =
          if trace?,
            do: for({index, row} <- :ets.tab2list(c.table), is_integer(index), do: row),
            else: []

        %{
          session_id: id,
          origin_us: c.origin,
          closed: c.closed,
          incomplete: Map.get(c, :incomplete, false),
          events_seen: count,
          truncated: count > state.limit,
          gap_events_seen: c.gap_events_seen,
          gaps_truncated: c.gap_events_seen > 512,
          events: rows,
          gaps: Enum.reverse(c.gaps)
        }
      end

    {:reply,
     %{
       schema_version: 1,
       clock: "server_local_monotonic",
       calls: Enum.sort_by(calls, & &1.origin_us)
     }, state}
  end

  @impl true
  def handle_info(
        {:parlora_event, %{session_id: id, type: :audio_observed, payload: payload}},
        state
      ) do
    case state.calls[id] do
      nil ->
        {:noreply, state}

      call ->
        # Only known classifications and numbers cross the retention boundary.
        labels =
          payload
          |> Map.take([:cause, :boundary, :recovery_release_reason])
          |> Map.filter(fn {_, v} ->
            v in [
              :source_queue_empty,
              :quiet_refill,
              :speech_continuation,
              :source_resumed,
              :cleared,
              :closed,
              :browser_pcm,
              :browser_rtp,
              :startup_capture_discard,
              :queue_ready,
              :deadline,
              :pressure,
              :buffering_disabled
            ]
          end)

        numbers =
          payload |> Map.take(@gap_measurements) |> Map.filter(fn {_, v} -> is_number(v) end)

        gap = Map.merge(labels, numbers)

        updated = %{
          call
          | gaps: Enum.take([gap | call.gaps], 512),
            gap_events_seen: call.gap_events_seen + 1
        }

        {:noreply, put_in(state.calls[id], updated)}
    end
  end

  def handle_info({:parlora_event, %{session_id: id, source: :session, type: :closed}}, state),
    do: {:noreply, close(state, id)}

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    ids = for {id, call} <- state.calls, call.pid == pid, do: id
    {:noreply, Enum.reduce(ids, state, &close(&2, &1))}
  end

  def handle_info({:parlora_unsubscribed, id, _reason}, state) do
    if state.calls[id],
      do: {:noreply, put_in(state.calls[id][:incomplete], true)},
      else: {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state), do: :telemetry.detach(__MODULE__)

  defp close(state, id) do
    :ets.delete(state.routes, id)
    if state.calls[id], do: put_in(state.calls[id].closed, true), else: state
  end
end
