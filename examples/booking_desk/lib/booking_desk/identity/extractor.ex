defmodule BookingDesk.Identity.Extractor do
  alias BookingDesk.Identity.LLM

  @moduledoc "Debounced, bounded extraction outside the session/audio loop; stale caller revisions are inert."
  use GenServer

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  def check(state, server \\ __MODULE__), do: GenServer.call(server, {:check, state})

  def init(opts) do
    {:ok,
     %{
       entries: %{},
       field: Keyword.get(opts, :field, :identity),
       evaluator: Keyword.get(opts, :evaluator, &LLM.extract/1),
       debounce_ms: Keyword.get(opts, :debounce_ms, 600),
       timeout_ms: Keyword.get(opts, :timeout_ms, 4_500),
       max_evaluations: Keyword.get(opts, :max_evaluations, 12)
     }}
  end

  def format_status(status),
    do:
      Map.merge(status, %{state: %{requests: map_size(status.state.entries)}, message: :redacted})

  def handle_call(
        {:check,
         %{interpretation_binding: %{session_id: session, provider_generation: generation}} =
           state},
        _from,
        s
      ) do
    if Enum.any?(s.entries, fn {{id, gen}, _} -> id == session and gen > generation end),
      do: {:reply, {:error, :stale}, s},
      else: check_current(state, s)
  end

  def handle_call({:check, _}, _from, s), do: {:reply, {:error, :invalid_extraction}, s}

  defp check_current(state, s) do
    case input(state) do
      {:ok, slot, key, source} ->
        s = admit(s, slot)
        old = Map.get(s.entries, slot, %{key: nil, job: nil, timer: nil, attempts: 0})

        entry =
          if old.key == key do
            old
          else
            old = cancel(old)
            timer = Process.send_after(self(), {:launch, slot, key}, s.debounce_ms)

            %{
              key: key,
              input: source,
              job: nil,
              timer: timer,
              attempts: old.attempts,
              result: :pending,
              touched: System.monotonic_time(:millisecond)
            }
          end

        {:reply, entry.result, %{s | entries: Map.put(s.entries, slot, entry)}}

      _ ->
        {:reply, {:error, :invalid_extraction}, s}
    end
  end

  def handle_info({:launch, slot, key}, s) do
    case s.entries[slot] do
      %{key: ^key, job: nil, result: :pending} = entry ->
        entry =
          if entry.attempts < s.max_evaluations do
            launch(entry, s)
          else
            :telemetry.execute(
              [:booking_desk, :extraction, :stop],
              %{duration_us: 0, attempt: entry.attempts},
              %{field: s.field, outcome: :error, reason: :budget_exhausted}
            )

            %{entry | result: {:error, :unavailable}, timer: nil}
          end

        {:noreply, %{s | entries: Map.put(s.entries, slot, entry)}}

      _ ->
        {:noreply, s}
    end
  end

  def handle_info({ref, result}, s) when is_reference(ref) do
    {:noreply, finish(s, ref, result)}
  end

  def handle_info({:deadline, ref}, s), do: {:noreply, finish(s, ref, {:error, :unavailable})}

  def handle_info({:DOWN, ref, :process, _, _}, s),
    do: {:noreply, finish(s, ref, {:error, :unavailable})}

  def handle_info(_, s), do: {:noreply, s}
  def terminate(_, s), do: Enum.each(s.entries, fn {_, entry} -> cancel(entry) end)

  defp input(
         %{
           interpretation_binding: %{
             session_id: session,
             provider_generation: generation,
             caller_cursor: cursor
           }
         } = state
       )
       when is_binary(session) and is_integer(generation) and is_integer(cursor) do
    source =
      Map.take(state, [
        :dialogue,
        :latest_user,
        :retained_identity,
        :retained_registration,
        :retained_phone_evidence
      ])

    if is_list(source[:dialogue]) and is_binary(source[:latest_user]) and
         String.trim(source.latest_user) != "" and byte_size(JSON.encode!(source)) <= 8_000 do
      key = :crypto.hash(:sha256, :erlang.term_to_binary({cursor, source}))
      {:ok, {session, generation}, key, source}
    else
      :error
    end
  end

  defp input(_), do: :error

  defp launch(entry, s) do
    evaluate = s.evaluator
    input = entry.input

    task =
      Task.Supervisor.async_nolink(BookingDesk.IdentityTasks, fn ->
        try do
          evaluate.(input)
        rescue
          _ -> {:error, :unavailable}
        catch
          _, _ -> {:error, :unavailable}
        end
      end)

    timer = Process.send_after(self(), {:deadline, task.ref}, s.timeout_ms)

    %{
      entry
      | job: %{task: task, timer: timer, started_us: System.monotonic_time(:microsecond)},
        timer: nil,
        attempts: entry.attempts + 1
    }
  rescue
    _ -> %{entry | result: {:error, :unavailable}, timer: nil}
  end

  defp finish(s, ref, result) do
    entries =
      Map.new(s.entries, fn
        {slot, %{job: %{task: %{ref: ^ref}}} = entry} ->
          {outcome, reason} =
            case result do
              {:ok, _} -> {:ok, :accepted}
              {:incomplete, _} -> {:incomplete, :needs_clarification}
              {:incomplete, _, _} -> {:incomplete, :needs_clarification}
              {:error, :invalid_extraction} -> {:error, :invalid_extraction}
              _ -> {:error, :unavailable}
            end

          :telemetry.execute(
            [:booking_desk, :extraction, :stop],
            %{
              duration_us: System.monotonic_time(:microsecond) - entry.job.started_us,
              attempt: entry.attempts
            },
            %{field: s.field, outcome: outcome, reason: reason}
          )

          {slot, %{cancel(entry) | result: result}}

        other ->
          other
      end)

    %{s | entries: entries}
  end

  defp cancel(entry) do
    if entry.timer, do: Process.cancel_timer(entry.timer)

    if entry.job do
      Process.cancel_timer(entry.job.timer)
      Task.shutdown(entry.job.task, :brutal_kill)
    end

    %{entry | job: nil, timer: nil}
  end

  defp admit(s, slot) do
    # A new generation cancels work from older generations of the same session.
    entries =
      Enum.reject(s.entries, fn
        {{session, generation}, entry}
        when session == elem(slot, 0) and generation != elem(slot, 1) ->
          cancel(entry)
          true

        _ ->
          false
      end)
      |> Map.new()

    entries =
      if not Map.has_key?(entries, slot) and map_size(entries) >= 16 do
        {key, entry} = Enum.min_by(entries, fn {_, entry} -> entry.touched end)
        cancel(entry)
        Map.delete(entries, key)
      else
        entries
      end

    %{s | entries: entries}
  end
end
