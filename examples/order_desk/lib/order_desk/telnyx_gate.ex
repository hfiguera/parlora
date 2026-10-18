defmodule OrderDesk.TelnyxGate do
  @moduledoc "Supervised incoming-call admission, one-use media credentials and asynchronous commands."
  use GenServer
  alias OrderDesk.TelnyxCalls
  alias Parlora.Channels.Telnyx.Commands

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)
  def admit_request, do: GenServer.call(__MODULE__, :admit_request)
  def event(data), do: GenServer.call(__MODULE__, {:event, data}, 1_000)
  def claim(ticket, token), do: GenServer.call(__MODULE__, {:claim, ticket, token, self()}, 1_000)
  def observations, do: GenServer.call(__MODULE__, :observations)
  def drain, do: GenServer.call(__MODULE__, :drain)

  @impl true
  def init(options) do
    Process.send_after(self(), :sweep, 250)

    {:ok,
     %{
       calls: TelnyxCalls.new(Keyword.fetch!(options, :config)),
       executor: Keyword.get(options, :executor, &Commands.execute/5),
       supervisor: Keyword.fetch!(options, :task_supervisor),
       tickets: %{},
       workers: %{},
       pending: :queue.new(),
       commands: MapSet.new(),
       ended: MapSet.new(),
       slots: MapSet.new(),
       observations: [],
       draining: false,
       window: now(),
       requests: 0
     }}
  end

  @impl true
  def handle_call(:admit_request, _from, state) do
    state =
      if now() - state.window >= 1_000, do: %{state | window: now(), requests: 0}, else: state

    if state.requests < 20,
      do: {:reply, :ok, %{state | requests: state.requests + 1}},
      else: {:reply, {:error, :rate_limited}, state}
  end

  def handle_call({:event, event}, _from, state) do
    with {:ok, calls, actions} <- TelnyxCalls.admit(state.calls, event),
         :ok <- reserve(state, actions) do
      id = event["payload"]["call_control_id"]
      state = %{state | calls: calls}

      state =
        if event["event_type"] == "call.hangup",
          do: confirm_ended(state, id, :signed_webhook),
          else: state

      next = Enum.reduce(actions, state, &enqueue/2) |> observe(id, event["event_type"])
      send(self(), :pump)
      {:reply, :ok, next}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:claim, ticket, token, owner}, _from, state) do
    found = Enum.find(state.tickets, fn {_id, entry} -> entry.ticket == ticket end)

    case found do
      {id, %{owner: nil, token: expected, expires: expires} = entry} ->
        if expires > now() and is_binary(token) and Plug.Crypto.secure_compare(expected, token) and
             not state.calls.calls[id].terminal do
          Process.monitor(owner)
          entry = %{entry | owner: owner, token: nil}

          reply =
            {:ok, [call_control_id: id, call_session_id: state.calls.calls[id].call_session_id]}

          {:reply, reply, %{state | tickets: Map.put(state.tickets, id, entry)}}
        else
          {:reply, {:error, :invalid_ticket}, state}
        end

      _invalid ->
        {:reply, {:error, :invalid_ticket}, state}
    end
  end

  def handle_call(:observations, _from, state) do
    {:reply,
     %{
       calls: state.calls.calls,
       commands: Enum.reverse(state.observations),
       workers: map_size(state.workers),
       queued: :queue.len(state.pending),
       unconfirmed_calls: MapSet.size(state.slots)
     }, state}
  end

  def handle_call(:drain, _from, state) do
    next =
      Enum.reduce(Map.keys(state.calls.calls), %{state | draining: true}, &close_call(&2, &1))

    send(self(), :pump)
    {:reply, :ok, next}
  end

  @impl true
  def handle_info(:pump, state), do: {:noreply, pump(state)}

  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.workers, ref) do
      {nil, _workers} ->
        {:noreply, state}

      {%{job: job, timer: timer}, workers} ->
        Process.demonitor(ref, [:flush])
        Process.cancel_timer(timer)
        next = complete(%{state | workers: workers}, job, result)
        {:noreply, pump(next)}
    end
  end

  def handle_info({:command_timeout, ref}, state) do
    case state.workers[ref] do
      %{task: task} -> Process.exit(task.pid, :kill)
      nil -> :ok
    end

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, owner, _reason}, state) do
    case Map.pop(state.workers, ref) do
      {%{job: job, timer: timer}, workers} ->
        Process.cancel_timer(timer)
        next = complete(%{state | workers: workers}, job, {:error, :worker_terminated})
        {:noreply, pump(next)}

      {nil, _workers} ->
        next =
          Enum.reduce(state.tickets, state, fn
            {id, %{owner: ^owner}}, acc -> close_call(acc, id)
            _other, acc -> acc
          end)

        {:noreply, pump(next)}
    end
  end

  def handle_info(:sweep, state) do
    next =
      Enum.reduce(state.calls.calls, state, fn {id, call}, acc ->
        ticket = acc.tickets[id]
        expired = ticket != nil and ticket.owner == nil and ticket.expires <= now()
        if call.expires <= now() or expired, do: close_call(acc, id), else: acc
      end)

    Process.send_after(self(), :sweep, 250)
    {:noreply, pump(next)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def format_status(status), do: Map.merge(status, %{state: :redacted, message: :redacted})

  defp reserve(state, actions) do
    new =
      Enum.filter(actions, fn {action, id} ->
        action in [:answer, :streaming_start] and not MapSet.member?(state.slots, id)
      end)

    cond do
      new != [] and (state.draining or MapSet.size(state.slots) >= 4) -> {:error, :backpressure}
      :queue.len(state.pending) + length(actions) > 16 -> {:error, :backpressure}
      true -> :ok
    end
  end

  defp enqueue({:close_stream, id}, state), do: close_socket(state, id)

  defp enqueue({action, id}, state) do
    if MapSet.member?(state.commands, {action, id}) do
      state
    else
      {params, state} = parameters(action, id, state)

      job = %{
        action: action,
        call: id,
        params: params,
        id: Parlora.ID.new(),
        expires: now() + 8_000
      }

      %{
        state
        | pending: :queue.in(job, state.pending),
          commands: MapSet.put(state.commands, {action, id}),
          slots: if(action == :hangup, do: state.slots, else: MapSet.put(state.slots, id))
      }
    end
  end

  defp parameters(:answer, _id, state), do: {%{"send_silence_when_idle" => true}, state}
  defp parameters(:hangup, _id, state), do: {%{}, state}

  defp parameters(:streaming_start, id, state) do
    entry = %{
      ticket: Parlora.ID.new(),
      token: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
      expires: now() + 60_000,
      owner: nil
    }

    url =
      String.replace_prefix(state.calls.config.public_url, "https://", "wss://") <>
        "/telnyx/media/" <> entry.ticket

    {Commands.stream_options(url, entry.token),
     %{state | tickets: Map.put(state.tickets, id, entry)}}
  end

  defp pump(state) when map_size(state.workers) >= 4, do: state

  defp pump(state) do
    case :queue.out(state.pending) do
      {:empty, _pending} ->
        state

      {{:value, job}, pending} ->
        state = %{state | pending: pending}

        cond do
          MapSet.member?(state.ended, job.call) or
              (state.calls.calls[job.call].terminal and job.action != :hangup) ->
            pump(observe(state, job.call, {job.action, :superseded}))

          job.expires <= now() ->
            pump(complete(state, job, {:error, :admission_expired}))

          true ->
            timeout = job.expires - now()
            executor = state.executor
            options = [api_key: state.calls.config.api_key, timeout_ms: timeout]

            task =
              Task.Supervisor.async_nolink(state.supervisor, fn ->
                execute(executor, job, options)
              end)

            timer = Process.send_after(self(), {:command_timeout, task.ref}, timeout)

            pump(%{
              state
              | workers: Map.put(state.workers, task.ref, %{task: task, job: job, timer: timer})
            })
        end
    end
  end

  defp execute(executor, job, options) do
    executor.(job.action, job.call, job.id, job.params, options)
  rescue
    _error -> {:error, :worker_failed}
  catch
    _kind, _reason -> {:error, :worker_failed}
  end

  defp complete(state, job, {:ok, _accepted}),
    do: observe(state, job.call, {job.action, :accepted})

  defp complete(state, job, failure) do
    outcome = %{action: job.action, status: :unknown, error: command_error(failure)}
    next = observe(state, job.call, outcome)

    cond do
      job.action != :hangup ->
        close_call(next, job.call)

      MapSet.member?(state.ended, job.call) ->
        reconcile_hangup(next, job.call, :confirmed_call_end)

      outcome.error[:remote_call_state] == :ended ->
        confirm_ended(next, job.call, :api_response)

      true ->
        next
    end
  end

  defp command_error({:error, %Parlora.Error{code: code, details: details}}),
    do:
      Map.put(
        Map.take(details, [
          :reason,
          :http_status,
          :attempts,
          :outcome,
          :telnyx_codes,
          :remote_call_state
        ]),
        :code,
        code
      )

  defp command_error({:error, reason}) when is_atom(reason), do: %{reason: reason}
  defp command_error(_unexpected), do: %{reason: :invalid_worker_result}

  defp confirm_ended(state, id, evidence) do
    state = put_in(state, [:calls, :calls, id, :terminal], true)
    state = %{state | ended: MapSet.put(state.ended, id), slots: MapSet.delete(state.slots, id)}
    state |> close_socket(id) |> reconcile_hangup(id, evidence)
  end

  defp reconcile_hangup(state, id, evidence) do
    last =
      Enum.find(state.observations, fn observation ->
        observation.call_id == id and match?(%{action: :hangup}, observation.outcome)
      end)

    case last do
      %{outcome: %{status: :unknown}} ->
        observe(state, id, %{
          action: :hangup,
          status: :reconciled,
          resolution: :call_ended,
          evidence: evidence
        })

      _other ->
        state
    end
  end

  defp close_call(state, id) do
    {calls, actions} = TelnyxCalls.close(state.calls, id)
    Enum.reduce(actions, close_socket(%{state | calls: calls}, id), &enqueue/2)
  end

  defp close_socket(state, id) do
    case state.tickets[id] do
      %{owner: owner} when is_pid(owner) -> send(owner, {:parlora_media_stream, :close})
      _missing -> :ok
    end

    %{state | tickets: Map.delete(state.tickets, id)}
  end

  defp observe(state, id, {action, status}),
    do: observe(state, id, %{action: action, status: status})

  defp observe(state, id, outcome),
    do: %{
      state
      | observations:
          Enum.take([%{call_id: id, outcome: outcome, at_ms: now()} | state.observations], 128)
    }

  defp now, do: System.monotonic_time(:millisecond)
end
