defmodule Parlora.Session.Commands do
  @moduledoc false
  alias Parlora.{AdapterOwner, Error}

  # The inner built-in Adapter.call/3 has a one-second admission timeout. Allow
  # it to report its own uncertain outcome before declaring a callback stalled.
  @timeout_us 1_100_000

  def new, do: %{records: %{}, running: %{}, queues: %{}, keys: %{}}

  def run(state, role, callback, complete, options) do
    case enqueue(state, role, callback, complete, options) do
      {:ok, next} -> next
      error -> complete.(state, error)
    end
  end

  def cancel(state, key) do
    commands = state.startup.commands
    ref = commands.keys[key]

    case commands.records[ref] do
      %{started?: false} = record ->
        finish(
          state,
          ref,
          record,
          Error.tuple(:closed, "Command cancelled before invocation", %{
            execution: :never_submitted
          })
        )

      _other ->
        state
    end
  end

  def enqueue(state, role, callback, complete, options \\ []) do
    commands = state.startup.commands
    key = Keyword.get(options, :key, make_ref())

    case commands.keys[key] do
      nil -> admit(state, role, key, callback, complete, options)
      ref -> duplicate(state, ref, options)
    end
  end

  def result(state, reference, reply) do
    case state.startup.commands.records[reference] do
      %{started?: true} = record ->
        if System.monotonic_time(:microsecond) < record.deadline do
          state |> finish(reference, record, reply) |> dispatch(record.role)
        else
          send(self(), {:adapter_command_timeout, reference})
          state
        end

      _late ->
        state
    end
  end

  def timeout(state, reference) do
    case state.startup.commands.records[reference] do
      nil ->
        {state, false}

      record ->
        details =
          if record.started?, do: %{outcome: :unknown}, else: %{execution: :never_submitted}

        reply =
          Error.tuple(
            :timeout,
            "Adapter command deadline expired; do not retry automatically",
            details
          )

        next = finish(state, reference, record, reply)
        {if(record.started?, do: next, else: dispatch(next, record.role)), record.started?}
    end
  end

  def close(state) do
    Enum.reduce(state.startup.commands.records, state, fn {reference, record}, acc ->
      details = if record.started?, do: %{outcome: :unknown}, else: %{execution: :never_submitted}
      finish(acc, reference, record, Error.tuple(:closed, "Session is closing", details))
    end)
  end

  def public(state, role, callback, from, options \\ []) do
    case enqueue(
           state,
           role,
           callback,
           fn state, _reply -> state end,
           Keyword.put(options, :from, from)
         ) do
      {:ok, next} -> {:noreply, next}
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  defp admit(state, role, key, callback, complete, options) do
    limit =
      min(
        state.limits.max_records,
        state.limits.max_jobs + state.limits.max_pending_jobs +
          state.limits.max_pending_delegations
      )

    cond do
      state.status != :ready ->
        Error.tuple(:closed, "Session is closing")

      map_size(state.startup.commands.records) >= limit ->
        Error.tuple(:backpressure, "Adapter command capacity exhausted")

      true ->
        ref = make_ref()

        deadline =
          min(
            System.monotonic_time(:microsecond) + @timeout_us,
            Keyword.get(options, :deadline, System.monotonic_time(:microsecond) + @timeout_us)
          )

        wait = max(0, div(deadline - System.monotonic_time(:microsecond) + 999, 1_000))

        record = %{
          role: role,
          key: key,
          callback: callback,
          complete: complete,
          guard: Keyword.get(options, :guard, fn _state -> true end),
          start: Keyword.get(options, :start, fn state -> state end),
          signature: Keyword.get(options, :signature),
          callers: List.wrap(Keyword.get(options, :from)),
          deadline: deadline,
          started?: false,
          timer: Process.send_after(self(), {:adapter_command_timeout, ref}, wait)
        }

        commands = state.startup.commands
        queue = :queue.in(ref, Map.get(commands.queues, role, :queue.new()))

        commands = %{
          commands
          | records: Map.put(commands.records, ref, record),
            keys: Map.put(commands.keys, key, ref),
            queues: Map.put(commands.queues, role, queue)
        }

        {:ok, state |> put(commands) |> dispatch(role)}
    end
  end

  defp duplicate(state, ref, options) do
    commands = state.startup.commands
    record = commands.records[ref]

    cond do
      record.signature != Keyword.get(options, :signature) ->
        Error.tuple(:invalid_argument, "Conflicting pending command ID")

      length(record.callers) >= state.limits.max_subscribers and options[:from] != nil ->
        Error.tuple(:backpressure, "Pending command caller capacity exhausted")

      true ->
        record = %{record | callers: record.callers ++ List.wrap(Keyword.get(options, :from))}
        {:ok, put(state, %{commands | records: Map.put(commands.records, ref, record)})}
    end
  end

  defp dispatch(%{status: :ready} = state, role) do
    commands = state.startup.commands

    case {commands.running[role], :queue.out(Map.get(commands.queues, role, :queue.new()))} do
      {nil, {{:value, ref}, queue}} ->
        state = put(state, %{commands | queues: Map.put(commands.queues, role, queue)})

        case state.startup.commands.records[ref] do
          nil -> dispatch(state, role)
          record -> start(state, ref, record)
        end

      _other ->
        state
    end
  end

  defp dispatch(state, _role), do: state

  defp start(state, ref, record) do
    if record.guard.(state) and System.monotonic_time(:microsecond) < record.deadline do
      state = record.start.(state)
      owner = state.startup.owners[record.role].owner
      AdapterOwner.execute(owner, ref, prepare(record.callback, state), record.deadline)
      commands = state.startup.commands

      put(state, %{
        commands
        | running: Map.put(commands.running, record.role, ref),
          records: Map.put(commands.records, ref, %{record | started?: true})
      })
    else
      reply =
        Error.tuple(:invalid_argument, "Command expired or targets obsolete context", %{
          execution: :never_submitted
        })

      state |> finish(ref, record, reply) |> dispatch(record.role)
    end
  end

  # Only internal, pure payload builders run here. The returned adapter callback
  # still executes in its owner, with the same ordering and absolute deadline.
  defp prepare({:current, build}, state), do: build.(state)
  defp prepare(callback, _state), do: callback

  defp finish(state, ref, record, reply) do
    Process.cancel_timer(record.timer)
    Enum.each(record.callers, &GenServer.reply(&1, reply))
    commands = state.startup.commands
    queue = :queue.filter(&(&1 != ref), Map.get(commands.queues, record.role, :queue.new()))

    running =
      if commands.running[record.role] == ref,
        do: Map.delete(commands.running, record.role),
        else: commands.running

    state =
      put(state, %{
        commands
        | records: Map.delete(commands.records, ref),
          keys: Map.delete(commands.keys, record.key),
          queues: Map.put(commands.queues, record.role, queue),
          running: running
      })

    record.complete.(state, reply)
  end

  defp put(state, commands), do: %{state | startup: %{state.startup | commands: commands}}
end
