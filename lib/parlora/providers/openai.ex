defmodule Parlora.Providers.OpenAI do
  @moduledoc "GPT-Live-1 client delegation over Mint.WebSocket, with explicit application-owned credentials."
  use GenServer
  use Parlora.ProviderClient, protocol: Parlora.Providers.OpenAI.Protocol
  alias Mint.{HTTP, WebSocket}
  alias Parlora.{AudioFormat, AudioFrame, AudioQueue, CommandLog, Error, Event, ID, Pacer}
  alias Parlora.Provider.OutputBuffer
  alias Parlora.Providers.OpenAI.{AudioTrace, Diagnostics, Protocol, Recovery}

  @impl true
  def audio_limits(format \\ %AudioFormat{}), do: OutputBuffer.burst_limits(format, 2_000)

  @impl true
  def recover_output(pid, token, snapshot),
    do: Parlora.Adapter.call(pid, {:recover_output, token, snapshot})

  @impl true
  def init({init, options, startup}) do
    state = %{
      init: init,
      key: Keyword.fetch!(options, :api_key),
      startup: startup,
      startup_template: startup,
      recovery: nil,
      connection_worker: nil,
      transport_epoch: 0,
      timeline_offset_ms: 0,
      timeline_end_ms: 0,
      retired_delegations: MapSet.new(),
      deferred: [],
      input_muted: false,
      prior_usage_seconds: 0,
      usage_complete?: true,
      recovery_awaiting_user: false,
      recovery_delegations: [],
      diagnostics:
        Diagnostics.new(Keyword.get(options, :diagnostic_sink), %{
          session_id: init.session_id,
          adapter_id: init.adapter_id
        }),
      command_ack_timeout_ms: Keyword.get(options, :command_ack_timeout_ms, 30_000),
      conn: nil,
      websocket: nil,
      ref: nil,
      http_status: nil,
      headers: [],
      status: :connecting,
      inbound: OutputBuffer.new(init.limits),
      audio_waiter: nil,
      audio_trace: AudioTrace.new(System.monotonic_time(:microsecond)),
      outbound: %AudioQueue{capacity: init.limits.audio_queue_bytes},
      commands: %CommandLog{limit: init.limits.max_records},
      pending: %{},
      delegations: MapSet.new(),
      sequence: 0,
      usage: nil,
      finalized: false,
      deadline: System.monotonic_time(:microsecond)
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def format_status(status),
    do: Map.merge(status, %{state: %{status: status.state.status}, message: :redacted})

  @impl true
  def handle_continue(:connect, state) do
    Process.send_after(self(), :startup_timeout, state.init.limits.startup_timeout_ms)

    with {:ok, conn} <-
           HTTP.connect(:https, "api.openai.com", 443,
             protocols: [:http1],
             transport_opts: [timeout: 10_000, send_timeout: 1_000]
           ),
         {:ok, conn, ref} <-
           WebSocket.upgrade(:wss, conn, "/v1/live/sessions", [
             {"authorization", "Bearer " <> state.key}
           ]) do
      {:noreply, %{state | conn: conn, ref: ref}}
    else
      _error -> {:noreply, fail(state, :connection_failed)}
    end
  end

  @impl true
  def handle_call({:close, id, _reason}, _from, state) do
    if state.status in [:closed, :closing] do
      {:reply, :ok, state}
    else
      stop_worker(state.connection_worker)
      Process.send_after(self(), :close_timeout, state.init.limits.shutdown_timeout_ms)
      # Session audio pipelines have stopped. Release their buffers while leaving
      # the connection open for acknowledgments and final usage.
      state = %{
        state
        | audio_waiter: nil,
          inbound: AudioQueue.clear(state.inbound),
          outbound: AudioQueue.clear(state.outbound),
          connection_worker: nil,
          recovery: nil
      }

      state =
        if state.websocket,
          do: send_json(state, %{type: "session.close", event_id: id}),
          else: state

      {:reply, :ok, if(state.status == :closed, do: state, else: %{state | status: :closing})}
    end
  end

  def handle_call(
        {:recover_output, token, snapshot},
        _from,
        %{status: :recovering, recovery: %{token: token}} = state
      ) do
    if state.conn, do: HTTP.close(state.conn)
    worker = Recovery.connect(self(), token, state.key)

    state = %{
      state
      | conn: nil,
        websocket: nil,
        ref: nil,
        headers: [],
        http_status: nil,
        startup: Recovery.startup(state.startup_template, snapshot),
        connection_worker: worker,
        timeline_offset_ms: state.timeline_end_ms,
        transport_epoch: state.transport_epoch + 1,
        retired_delegations: state.delegations,
        prior_usage_seconds: get_in(state.usage || %{}, [:seconds]) || state.prior_usage_seconds,
        usage_complete?: false,
        recovery_awaiting_user: true,
        recovery_delegations: [],
        status: :connecting_recovery
    }

    {:reply, :ok, state}
  end

  def handle_call({:recover_output, _token, _snapshot}, _from, state),
    do: {:reply, Error.tuple(:invalid_argument, "Obsolete output recovery"), state}

  def handle_call(_command, _from, %{status: status} = state)
      when status not in [:ready, :recovering, :connecting_recovery, :starting_recovery] do
    code = if status in [:closing, :closed], do: :closed, else: :not_ready
    {:reply, Error.tuple(code, "Provider is not ready"), state}
  end

  def handle_call(:capabilities, _from, state),
    do: {:reply, {:ok, Protocol.capabilities()}, state}

  def handle_call(:output_buffer_status, _from, state),
    do:
      {:reply,
       {:ok, %{queued_bytes: state.inbound.bytes, capacity_bytes: state.inbound.capacity}}, state}

  def handle_call({:arm_output_ready, reader, reference}, _from, state)
      when is_pid(reader) and is_reference(reference) do
    state = %{state | audio_waiter: {reader, reference}}
    {:reply, :ok, notify_audio_ready(state)}
  end

  def handle_call({:read, budget}, _from, state) do
    case OutputBuffer.read(state.inbound, budget, state.init.limits, now(), state.init) do
      {:ok, frames, queue} ->
        trace =
          AudioTrace.record(
            state.audio_trace,
            :read,
            state.inbound.bytes - queue.bytes,
            queue.bytes,
            now()
          )

        {:reply, {:ok, frames},
         %{
           state
           | inbound: queue,
             audio_trace: trace,
             audio_waiter: if(frames == [], do: state.audio_waiter, else: nil)
         }}

      {:error, %Error{code: :output_stale} = error} ->
        {:reply, {:ok, []}, recover_audio(state, error, 0)}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:write, frame}, _from, %{recovery: recovery} = state)
      when not is_nil(recovery) do
    case AudioFrame.validate(frame, state.init.audio_format, state.init.limits) do
      :ok ->
        recovery = Map.update!(recovery, :dropped_input_bytes, &(&1 + byte_size(frame.data)))
        {:reply, :ok, %{state | recovery: recovery}}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:write, frame}, _from, state) do
    with :ok <- AudioFrame.validate(frame, state.init.audio_format, state.init.limits),
         {:ok, queue} <- AudioQueue.push(state.outbound, frame) do
      {:reply, :ok,
       %{
         state
         | outbound: queue,
           diagnostics: Diagnostics.accepted(state.diagnostics, frame.data)
       }}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:append, update}, _from, state) do
    case Protocol.append(update, state.init.generation, state.delegations) do
      {:ok, command} ->
        admit_command(state, update.id, command, :context)

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:control, id, control}, _from, state) do
    case Protocol.control(id, control) do
      {:ok, command} ->
        case admit_command(state, id, command, :control) do
          {:reply, :ok, next} ->
            next = remember_control(next, control)

            {:reply, :ok, next}

          error ->
            error
        end

      error ->
        {:reply, error, state}
    end
  end

  def handle_call(_command, _from, state),
    do: {:reply, Error.tuple(:invalid_argument, "Invalid provider command"), state}

  @impl true
  def handle_info({:send_audio, epoch}, %{transport_epoch: epoch} = state),
    do: handle_info(:send_audio, state)

  def handle_info({:send_audio, _old_epoch}, state), do: {:noreply, state}

  def handle_info(:send_audio, %{status: :ready} = state) do
    {frames, queue} = AudioQueue.pop(state.outbound, state.init.limits.max_frame_bytes)

    pcm =
      if frames == [],
        do: AudioFormat.silence(state.init.audio_format, 10),
        else: Enum.map_join(frames, & &1.data)

    state =
      send_json(%{state | outbound: queue}, %{
        type: "session.input_audio.append",
        audio: Base.encode64(pcm)
      })

    {deadline, wait_ms} =
      Pacer.next(state.deadline, AudioFormat.duration_us(state.init.audio_format, byte_size(pcm)))

    Process.send_after(self(), {:send_audio, state.transport_epoch}, wait_ms)
    {:noreply, %{state | deadline: deadline}}
  end

  def handle_info(:startup_timeout, %{status: status} = state)
      when status in [:connecting, :starting],
      do: {:noreply, fail(state, :startup_timeout)}

  def handle_info(:startup_timeout, state), do: {:noreply, state}

  def handle_info({:command_ack_timeout, id}, %{status: :ready} = state) do
    if Map.has_key?(state.pending, id),
      do: {:noreply, fail(state, :command_ack_timeout)},
      else: {:noreply, state}
  end

  def handle_info({:command_ack_timeout, _id}, state), do: {:noreply, state}
  def handle_info(:send_audio, state), do: {:noreply, state}
  def handle_info(:close_timeout, %{status: :closed} = state), do: {:noreply, state}

  def handle_info(:close_timeout, state),
    do: {:noreply, finish(state, %{finalized?: false, reason: :timeout})}

  def handle_info(
        {:output_connection, token, {:ok, conn, ref}},
        %{status: :connecting_recovery, recovery: %{token: token}} = state
      ) do
    retire_worker(state.connection_worker)

    case HTTP.set_mode(conn, :active) do
      {:ok, conn} ->
        {:noreply,
         %{state | conn: conn, ref: ref, status: :starting_recovery, connection_worker: nil}}

      _error ->
        HTTP.close(conn)
        {:noreply, fail(state, :recovery_connection_failed)}
    end
  end

  def handle_info({:output_connection, _token, {:ok, conn, _ref}}, state) do
    HTTP.close(conn)
    {:noreply, state}
  end

  def handle_info(
        {:output_connection, token, {:error, _reason}},
        %{recovery: %{token: token}} = state
      ),
      do: {:noreply, fail(state, :recovery_connection_failed)}

  def handle_info({:output_recovery_timeout, token}, %{recovery: %{token: token}} = state),
    do: {:noreply, fail(state, :recovery_timeout)}

  def handle_info({:output_recovery_timeout, _token}, state), do: {:noreply, state}

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{connection_worker: {_worker, ref}} = state
      ),
      do: {:noreply, fail(state, :recovery_connection_failed)}

  def handle_info(_message, %{conn: nil} = state), do: {:noreply, state}

  def handle_info(message, state) do
    case WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        {:noreply, Enum.reduce(responses, %{state | conn: conn}, &response/2)}

      {:error, conn, _reason, responses} ->
        state = Enum.reduce(responses, %{state | conn: conn}, &response/2)

        {:noreply,
         if(state.finalized or state.status == :recovering,
           do: state,
           else: fail(state, :connection_lost)
         )}

      :unknown ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    stop_worker(state.connection_worker)
    Diagnostics.finish(state.diagnostics, :terminated)
    if state.conn, do: HTTP.close(state.conn)
    :ok
  end

  defp remember_control(state, {:input_muted, flag}), do: %{state | input_muted: flag}
  defp remember_control(state, _control), do: state

  defp send_command?(state, command),
    do:
      state.status == :ready and
        (not state.recovery_awaiting_user or command.type != "session.commentary.append")

  defp flush_deferred(state) do
    Enum.reduce(Enum.reverse(state.deferred), %{state | deferred: []}, fn {id, command}, acc ->
      if send_command?(acc, command) do
        Process.send_after(self(), {:command_ack_timeout, id}, acc.command_ack_timeout_ms)
        send_json(acc, wire_command(acc, command))
      else
        %{acc | deferred: [{id, command} | acc.deferred]}
      end
    end)
  end

  defp admit_command(state, id, command, kind) do
    case CommandLog.admit(state.commands, id, command) do
      {:duplicate, _log} ->
        {:reply, :ok, state}

      {:new, log} ->
        state = %{state | commands: log, pending: Map.put(state.pending, id, kind)}

        if send_command?(state, command) do
          Process.send_after(self(), {:command_ack_timeout, id}, state.command_ack_timeout_ms)
          {:reply, :ok, send_json(state, wire_command(state, command))}
        else
          {:reply, :ok, %{state | deferred: [{id, command} | state.deferred]}}
        end

      error ->
        {:reply, error, state}
    end
  end

  defp wire_command(state, command) do
    if MapSet.member?(state.retired_delegations, command[:delegation_id]),
      do: Map.put(command, :delegation_id, nil),
      else: command
  end

  defp response(_response, %{status: :closed} = state), do: state

  defp response({:status, _ref, status}, state), do: %{state | http_status: status}
  defp response({:headers, _ref, headers}, state), do: %{state | headers: headers}

  defp response({:done, _ref}, %{websocket: nil, http_status: 101} = state) do
    case WebSocket.new(state.conn, state.ref, 101, state.headers, mode: :active) do
      {:ok, conn, websocket} ->
        status = if state.recovery, do: :starting_recovery, else: :starting
        send_json(%{state | conn: conn, websocket: websocket, status: status}, state.startup)

      _error ->
        fail(state, :upgrade_failed)
    end
  end

  defp response({:done, _ref}, state), do: fail(state, :upgrade_rejected)

  defp response({:data, _ref, data}, %{websocket: websocket} = state) when websocket != nil do
    if byte_size(data) + :erlang.external_size(websocket) <= 1_048_576 do
      case WebSocket.decode(websocket, data) do
        {:ok, websocket, frames} -> Enum.reduce(frames, %{state | websocket: websocket}, &frame/2)
        _error -> fail(state, :malformed_websocket)
      end
    else
      fail(state, :oversized_websocket)
    end
  end

  defp response(_response, state), do: state

  defp frame(_frame, %{status: :closed} = state), do: state

  defp frame(_frame, %{status: :recovering} = state), do: state

  defp frame({:text, json}, state) do
    case JSON.decode(json) do
      {:ok, event} ->
        state = %{state | diagnostics: Diagnostics.received(state.diagnostics, event)}
        handle_event(Protocol.translate(event), state)

      {:error, _error} ->
        fail(state, :invalid_json)
    end
  end

  defp frame({:ping, data}, state), do: send_frame(state, {:pong, data})

  defp frame({:close, _code, _reason}, state),
    do: finish(state, %{finalized?: state.finalized, reason: :socket_closed})

  defp frame({:error, _error}, state), do: fail(state, :malformed_frame)
  defp frame(_frame, state), do: state

  defp handle_event({:ready, session}, %{status: :starting} = state) do
    Event.emit(state.init, :provider, :ready, %{
      capabilities: Protocol.capabilities(),
      format: state.init.audio_format,
      provider_session_id: session["id"]
    })

    send(self(), :send_audio)
    %{state | status: :ready, deadline: System.monotonic_time(:microsecond)}
  end

  defp handle_event({:ready, session}, %{status: :starting_recovery} = state) do
    Event.emit(state.init, :provider, :audio_discontinuity, %{
      direction: :input,
      cause: :voice_transport_recovery,
      dropped_bytes: state.recovery.dropped_input_bytes,
      dropped_duration_us:
        AudioFormat.duration_us(state.init.audio_format, state.recovery.dropped_input_bytes)
    })

    Event.emit(state.init, :provider, :output_recovered, %{
      token: state.recovery.token,
      transport_epoch: state.transport_epoch,
      provider_session_id: session["id"],
      previous_usage: state.usage,
      previous_finalized?: false
    })

    state = %{
      state
      | status: :ready,
        recovery: nil,
        usage: nil,
        finalized: false,
        deadline: now()
    }

    state =
      if state.input_muted,
        do: send_json(state, %{type: "session.input_audio.mute", event_id: ID.new()}),
        else: state

    command = %{
      type: "session.instructions.append",
      event_id: ID.new(),
      delegation_id: nil,
      content: Recovery.announcement()
    }

    state =
      case admit_command(state, command.event_id, command, :context) do
        {:reply, :ok, next} -> flush_deferred(next)
        _error -> fail(state, :recovery_announcement_failed)
      end

    send(self(), :send_audio)
    state
  end

  defp handle_event({:audio, _encoded}, %{status: :closing} = state), do: state

  defp handle_event({:audio, encoded}, state) do
    case Base.decode64(encoded) do
      {:ok, pcm} ->
        queue_audio(state, pcm)

      _invalid ->
        fail(state, :invalid_audio)
    end
  end

  defp handle_event({:delegation, payload}, %{recovery_awaiting_user: true} = state) do
    if length(state.recovery_delegations) < state.init.limits.max_pending_delegations,
      do: %{state | recovery_delegations: [payload | state.recovery_delegations]},
      else: state
  end

  defp handle_event({:delegation, payload}, state) do
    payload =
      if is_number(payload.offset_ms),
        do: %{payload | offset_ms: payload.offset_ms + state.timeline_offset_ms},
        else: payload

    if MapSet.size(state.delegations) < state.init.limits.max_records do
      Event.emit(state.init, :provider, :delegation_requested, payload)
      %{state | delegations: MapSet.put(state.delegations, payload.id)}
    else
      fail(state, :delegation_capacity)
    end
  end

  defp handle_event({:event, type, payload, command_id}, state) do
    awaiting_user = state.recovery_awaiting_user

    payload =
      if type == :transcript_delta,
        do: %{
          payload
          | start_ms: payload.start_ms + state.timeline_offset_ms,
            end_ms: payload.end_ms + state.timeline_offset_ms
        },
        else: payload

    state =
      if type == :transcript_delta,
        do: %{
          state
          | timeline_end_ms: max(state.timeline_end_ms, payload.end_ms),
            recovery_awaiting_user:
              state.recovery_awaiting_user and
                not (payload.speaker == :user and String.trim(payload.delta) != "")
        },
        else: state

    payload = if type == :usage_updated, do: total_usage(state, payload), else: payload
    Event.emit(state.init, :provider, type, payload, command_id: command_id)
    state = if type == :usage_updated, do: %{state | usage: payload}, else: state

    if awaiting_user and not state.recovery_awaiting_user,
      do: state |> release_delegations(payload.start_ms) |> flush_deferred(),
      else: state
  end

  defp handle_event({:ack, type, id, payload}, state) do
    Event.emit(state.init, :provider, type, payload, command_id: id)
    %{state | pending: Map.delete(state.pending, id)}
  end

  defp handle_event({:error, id, error}, state) do
    details =
      Map.new(error.details, fn {key, value} ->
        {key,
         if(is_binary(value), do: String.replace(value, state.key, "[REDACTED]"), else: value)}
      end)

    error = %{
      error
      | message: String.replace(error.message, state.key, "[REDACTED]"),
        details: details
    }

    type = if state.pending[id] == :context, do: :context_rejected, else: :control_failed
    Event.emit(state.init, :provider, type, %{error: error}, command_id: id)
    state = %{state | pending: Map.delete(state.pending, id)}
    if state.status == :starting, do: fail(state, :startup_rejected), else: state
  end

  defp handle_event({:closed, payload}, state) do
    usage = total_usage(state, payload.usage)
    Event.emit(state.init, :provider, :usage_final, usage)
    payload = %{payload | usage: usage, finalized?: state.usage_complete?}
    finish(%{state | usage: usage, finalized: true}, payload)
  end

  defp handle_event(_event, state), do: state

  defp release_delegations(state, user_start_ms) do
    Enum.reduce(
      Enum.reverse(state.recovery_delegations),
      %{state | recovery_delegations: []},
      fn payload, acc ->
        # Live may delegate before sending its caller caption. Retain those calls
        # until the first fresh caller interval establishes a causal boundary;
        # never replay a history-triggered call from before that speech.
        if is_number(payload.offset_ms) and
             payload.offset_ms + state.timeline_offset_ms >= user_start_ms,
           do: handle_event({:delegation, payload}, acc),
           else: acc
      end
    )
  end

  defp total_usage(%{prior_usage_seconds: prior, usage_complete?: complete}, usage) do
    seconds = if is_number(usage[:seconds]), do: prior + usage.seconds, else: nil
    Map.merge(usage, %{seconds: seconds, complete?: complete})
  end

  defp notify_audio_ready(%{audio_waiter: {reader, reference}, inbound: %{bytes: bytes}} = state)
       when bytes > 0 do
    send(reader, {:parlora_audio_ready, self(), reference})
    %{state | audio_waiter: nil}
  end

  defp notify_audio_ready(state), do: state

  defp queue_audio(state, pcm) do
    trace =
      AudioTrace.record(state.audio_trace, :received, byte_size(pcm), state.inbound.bytes, now())

    state = %{state | audio_trace: trace}

    case OutputBuffer.push(state.inbound, pcm, state.init, state.sequence, now()) do
      {:ok, {queue, sequence}} ->
        notify_audio_ready(%{state | inbound: queue, sequence: sequence})

      {:error, error} ->
        recover_audio(state, error, byte_size(pcm))
    end
  end

  defp recover_audio(state, %Error{code: code} = error, incoming_bytes)
       when code in [:output_overflow, :output_stale] do
    Event.emit(state.init, :provider, :audio_discontinuity, %{
      cause: error.code,
      dropped_bytes: state.inbound.bytes + incoming_bytes,
      queue_bytes: state.inbound.bytes,
      incoming_bytes: incoming_bytes,
      oldest_age_us: oldest_age(state.inbound, now()),
      audio_trace: AudioTrace.report(state.audio_trace, now()),
      capacity_bytes: state.inbound.capacity,
      max_age_ms: state.init.limits.provider_audio_max_age_ms
    })

    token = state.transport_epoch + 1
    Process.send_after(self(), {:output_recovery_timeout, token}, Recovery.timeout_ms())

    Event.emit(state.init, :provider, :output_recovery_requested, %{
      token: token,
      cause: error.code
    })

    deferred_ids = Enum.map(state.deferred, &elem(&1, 0))

    Enum.each(Map.drop(state.pending, deferred_ids), fn {id, kind} ->
      type = if kind == :context, do: :context_rejected, else: :control_failed
      Event.emit(state.init, :provider, type, %{outcome: :unknown}, command_id: id)
    end)

    %{
      state
      | inbound: AudioQueue.clear(state.inbound),
        audio_waiter: nil,
        status: :recovering,
        recovery: %{token: token, dropped_input_bytes: state.outbound.bytes},
        pending: Map.take(state.pending, deferred_ids),
        outbound: AudioQueue.clear(state.outbound)
    }
  end

  defp recover_audio(state, error, _incoming_bytes), do: fail(state, error.code)

  defp retire_worker(nil), do: :ok
  defp retire_worker({_pid, ref}), do: Process.demonitor(ref, [:flush])
  defp stop_worker(nil), do: :ok

  defp stop_worker({pid, ref}) do
    Process.demonitor(ref, [:flush])
    Process.exit(pid, :kill)
  end

  defp oldest_age(queue, now) do
    case :queue.peek(queue.items) do
      {:value, frame} -> max(0, now - frame.timestamp_us)
      :empty -> 0
    end
  end

  defp now, do: System.monotonic_time(:microsecond)

  defp send_json(state, command) do
    next = send_frame(state, {:text, JSON.encode!(command)})

    if next.status == :closed,
      do: next,
      else: %{next | diagnostics: Diagnostics.sent(next.diagnostics, command)}
  end

  defp send_frame(state, frame) do
    with {:ok, websocket, bytes} <- WebSocket.encode(state.websocket, frame),
         {:ok, conn} <- WebSocket.stream_request_body(state.conn, state.ref, bytes) do
      %{state | conn: conn, websocket: websocket}
    else
      _error -> fail(state, :send_failed)
    end
  end

  defp fail(state, reason) do
    Event.emit(state.init, :provider, :failed, %{
      cause: reason,
      error: Error.new(:adapter_failed, "Provider connection failed", %{reason: reason})
    })

    finish(state, %{finalized?: false, reason: reason})
  end

  defp finish(%{status: :closed} = state, _payload), do: state

  defp finish(state, payload) do
    Enum.each(state.pending, fn {id, kind} ->
      type = if kind == :context, do: :context_rejected, else: :control_failed

      Event.emit(
        state.init,
        :provider,
        type,
        %{
          outcome: :unknown,
          error: Error.new(:closed, "No acknowledgment observed before close")
        },
        command_id: id
      )
    end)

    stop_worker(state.connection_worker)
    diagnostics = Diagnostics.finish(state.diagnostics, :closed)
    if state.conn, do: HTTP.close(state.conn)
    Event.emit(state.init, :provider, :closed, Map.put(payload, :usage, state.usage))

    %{
      state
      | conn: nil,
        diagnostics: diagnostics,
        websocket: nil,
        key: nil,
        pending: %{},
        deferred: [],
        recovery: nil,
        connection_worker: nil,
        audio_waiter: nil,
        status: :closed
    }
  end
end
