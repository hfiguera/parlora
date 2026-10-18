# Run from the standalone consumer: MIX_ENV=test mix run /path/to/this/file
# Offline regression check: real AppPolicy/session/Jido/SQLite, scripted classifier/provider.
defmodule ClarificationTimingProbe do
  alias OrderDesk.ScriptedProvider
  alias Parlora.Event

  def run(mode) do
    started = System.monotonic_time(:millisecond)
    resolved = :atomics.new(1, [])
    owner = self()

    classify = fn state ->
      result =
        cond do
          String.contains?(state.caller_history, "No sorry") ->
            if :atomics.get(resolved, 1) == 1,
              do: {:ok, %{intent: "status", order: "123"}},
              else: {:error, :uncertain}

          String.contains?(state.caller_history, "Actually") ->
            {:ok, %{intent: "status", order: "124"}}

          true ->
            {:ok, %{intent: "status", order: "123"}}
        end

      send(owner, {:judgment, state.caller_history, result})
      result
    end

    {:ok, session} =
      OrderDesk.start_session(
        {Parlora.Channels.LocalAudio, device: :synthetic},
        {ScriptedProvider, observer: self(), audio: false},
        context_policy: {OrderDesk.AppPolicy, classify: classify}
      )

    try do
      provider = receive do: ({:scripted_provider, pid} -> pid)
      event(:ready)
      ScriptedProvider.say(provider, "Check order 123")
      ScriptedProvider.delegate(provider, "first")
      event(:task_submitted)
      context("Order 123 is")
      ScriptedProvider.say(provider, " Actually I mean 124")
      event(:task_submitted)
      context("Order 124 is")

      fragment = if mode == :streaming, do: " No sorry,", else: " No sorry, go back to 123"
      ScriptedProvider.say(provider, fragment)
      event(:context_wait_started)
      [{id, first}] = Map.to_list(Parlora.snapshot(session).tasks)
      due = first.context_wait.due_at_us

      if mode == :streaming do
        Process.sleep(900)
        ScriptedProvider.say(provider, " go back to")
        Process.sleep(50)
        true = Parlora.snapshot(session).tasks[id].context_wait.due_at_us > due
        IO.puts("#{mode}: more caller text arrived; clarification deadline renewed")
        Process.sleep(900)
      end

      if mode == :complete_but_uncertain do
        event(:context_wait_started)

        true =
          String.ends_with?(
            Parlora.snapshot(session).tasks[id].context_wait.recheck_key,
            ":verify"
          )
      end

      :atomics.put(resolved, 1, 1)
      if mode == :streaming, do: ScriptedProvider.say(provider, " 123")

      third = event(:task_submitted).payload.request
      "123" = third.input.order
      3 = third.task_revision
      result = context("Order 123 is")
      false = Map.has_key?(Parlora.snapshot(session).tasks[id], :clarification)

      receive do
        {:context, extra} -> raise "Unexpected extra context: #{extra.content}"
      after
        700 -> :ok
      end

      IO.puts("#{mode}: revision 3 result delivered without a clarification: #{result.content}")
      IO.puts("#{mode}: passed in #{System.monotonic_time(:millisecond) - started} ms")
    after
      Parlora.close(session, :cancel)
    end
  end

  defp event(type) do
    receive do
      {:parlora_event, %Event{source: :session, type: ^type} = event} -> event
    after
      5_000 -> raise "Missing event #{type}"
    end
  end

  defp context(fragment) do
    receive do
      {:context, update} ->
        if String.contains?(update.content, fragment),
          do: update,
          else: raise("Unexpected context: #{update.content}")
    after
      5_000 -> raise "Missing context #{fragment}"
    end
  end
end

for mode <- [:streaming, :complete_but_uncertain] do
  task = Task.async(fn -> ClarificationTimingProbe.run(mode) end)
  Task.await(task, 15_000)
end
