defmodule OrderDesk.PhoneDiagnostics do
  @moduledoc "Bounded, in-memory development evidence. No raw audio, credentials or automatic disk writes."
  use GenServer

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)
  def attach(session), do: GenServer.call(__MODULE__, {:attach, session})
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)
  def control(id, operation), do: GenServer.call(__MODULE__, {:control, id, operation})

  @impl true
  def init(_options), do: {:ok, %{}}

  @impl true
  def handle_call({:attach, pid}, _from, state) do
    snapshot = Parlora.snapshot(pid)
    :ok = Parlora.subscribe(pid, self())
    Process.monitor(pid)

    entry = %{
      pid: pid,
      started: System.monotonic_time(:microsecond),
      closed: false,
      events: [],
      jobs: %{},
      playback: %{},
      audio_peaks: %{},
      status: Parlora.status(pid)
    }

    retained =
      state
      |> Enum.sort_by(fn {_id, call} -> call.started end, :desc)
      |> Enum.take(7)
      |> Map.new()

    {:reply, :ok, Map.put(retained, snapshot.session_id, entry)}
  end

  def handle_call(:snapshot, _from, state) do
    refreshed = Map.new(state, fn {id, entry} -> {id, refresh(entry)} end)

    data =
      Map.new(refreshed, fn {id, entry} ->
        {id, entry |> Map.delete(:pid) |> Map.update!(:events, &Enum.reverse/1)}
      end)

    {:reply, data, refreshed}
  end

  def handle_call({:control, session_id, operation}, _from, state) do
    command =
      case operation do
        "clear" -> {:clear_output, :next}
        "suppress" -> {:suppress_output, true}
        "resume" -> {:suppress_output, false}
        _invalid -> :unsupported
      end

    id = Parlora.ID.new()

    reply =
      case state[session_id] do
        %{closed: false, pid: pid} when command != :unsupported ->
          case Parlora.control(pid, command, id) do
            :ok -> {:ok, id}
            _error -> {:error, :control_failed}
          end

        _missing ->
          {:error, :no_session}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info({:parlora_event, event}, state) do
    case state[event.session_id] do
      nil -> {:noreply, state}
      entry -> {:noreply, Map.put(state, event.session_id, record(entry, event))}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state),
    do:
      {:noreply,
       Map.new(state, fn {id, entry} ->
         {id, if(entry.pid == pid, do: %{entry | closed: true}, else: entry)}
       end)}

  def handle_info({:parlora_unsubscribed, id, _reason}, state) do
    case state[id] do
      nil -> {:noreply, state}
      entry -> {:noreply, Map.put(state, id, Map.put(entry, :incomplete, true))}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def format_status(status), do: Map.merge(status, %{state: :redacted, message: :redacted})

  defp record(entry, %{type: :playback_observed, payload: payload}) do
    peaks =
      Enum.reduce(
        [:queued_bytes, :inflight_bytes, :ack_latency_us, :queue_age_us],
        entry.audio_peaks,
        fn key, peaks ->
          if is_number(payload[key]),
            do: Map.update(peaks, key, payload[key], &max(&1, payload[key])),
            else: peaks
        end
      )

    %{
      entry
      | audio_peaks: peaks,
        playback: Map.update(entry.playback, payload.stage, 1, &(&1 + 1))
    }
  end

  defp record(entry, event) do
    payload =
      Map.take(event.payload, [
        :stage,
        :cause,
        :delta,
        :speaker,
        :evidence,
        :boundary,
        :reason,
        :scope,
        :dropped_bytes,
        :dropped_frames,
        :dropped_duration_us,
        :queued_bytes,
        :inflight_bytes,
        :finalized?,
        :usage,
        :epoch
      ])

    payload =
      case Map.get(event.payload, :error) do
        %{code: code, details: %{reason: :playback_ack_timeout} = details} ->
          Map.put(payload, :error, %{
            code: code,
            details: Map.take(details, [:reason, :inflight_bytes, :pending_marks])
          })

        %{code: code} ->
          Map.put(payload, :error, %{code: code})

        _missing ->
          payload
      end

    item = %{
      type: event.type,
      source: event.source,
      request_id: event.request_id,
      command_id: event.command_id,
      observed_at_us: event.observed_at_us,
      payload: payload
    }

    entry = %{entry | events: Enum.take([item | entry.events], 1_024)}

    entry =
      case event do
        %{type: :task_submitted, payload: %{request: request}} ->
          job = %{
            id: request.id,
            task_id: request.task_id,
            revision: request.task_revision,
            input: Map.take(request.input, [:order, :operation, :instructions])
          }

          %{entry | jobs: entry.jobs |> Map.put(request.id, job) |> Enum.take(64) |> Map.new()}

        _other ->
          entry
      end

    entry = refresh(entry)

    if event.source == :session and event.type == :closed,
      do: %{entry | closed: true},
      else: entry
  end

  defp refresh(%{closed: true} = entry), do: entry

  defp refresh(entry) do
    case Parlora.status(entry.pid) do
      %{session_id: _id} = status -> %{entry | status: status}
      _closed -> entry
    end
  catch
    :exit, _closed -> entry
  end
end
