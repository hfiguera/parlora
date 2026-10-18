defmodule DiagnosticTrace do
  def normalize(%_{} = value), do: normalize(Map.from_struct(value))

  def normalize(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {to_string(k), normalize(v)} end)

  def normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)
  def normalize(value) when is_tuple(value), do: value |> Tuple.to_list() |> normalize()

  def normalize(value) when is_pid(value) or is_reference(value) or is_function(value),
    do: inspect(value)

  def normalize(value), do: value

  def loop(path, remaining) when remaining > 0 do
    receive do
      {:trace, pid, kind, {module, function, args}} when kind == :call ->
        data =
          if module == OrderDesk.AppPolicy do
            [snapshot, trigger, _options] = args

            [
              Map.take(snapshot, [
                :session_id,
                :revision,
                :transcripts,
                :tasks,
                :pending_delegations
              ]),
              trigger
            ]
          else
            args
          end

        write(path, pid, kind, module, function, data)
        loop(path, remaining - 1)

      {:trace, pid, :return_from, {module, function, _arity}, result} ->
        write(path, pid, :return, module, function, result)
        loop(path, remaining - 1)

      _ ->
        loop(path, remaining)
    end
  end

  def loop(_, _), do: :erlang.trace(:all, false, [:call])

  defp write(path, pid, kind, module, function, data) do
    File.write!(
      path,
      Jason.encode!(%{
        us: System.monotonic_time(:microsecond),
        pid: inspect(pid),
        kind: kind,
        module: inspect(module),
        function: function,
        data: normalize(data)
      }) <> "\n",
      [:append]
    )
  end
end

path = "/tmp/parlora-completed-tail-fixed.jsonl"
File.write!(path, "")
tracer = spawn(fn -> DiagnosticTrace.loop(path, 3000) end)
for module <- [OrderDesk.AppPolicy, OrderDesk.Interpretation], do: Code.ensure_loaded!(module)

for mfa <- [
      {OrderDesk.AppPolicy, :interpret, 3},
      {OrderDesk.Interpretation, :classify, 2},
      {OrderDesk.Interpretation, :interpret_answers, 1}
    ] do
  :erlang.trace_pattern(mfa, [{:_, [], [{:return_trace}]}], [:local])
end

:erlang.trace(:all, true, [:call, {:tracer, tracer}])

defmodule TailReplay do
  def event(type) do
    receive do
      {:parlora_event, %Parlora.Event{source: :session, type: ^type} = event} -> event
    after
      10_000 -> raise "Missing event #{type}"
    end
  end

  def context do
    receive do
      {:context, update} -> update
    after
      10_000 -> raise "Missing provider context"
    end
  end
end

{:ok, session} =
  OrderDesk.start_session(
    {Parlora.Channels.LocalAudio, device: :synthetic},
    {OrderDesk.ScriptedProvider, observer: self(), audio: false},
    context_policy: {OrderDesk.AppPolicy, []}
  )

receive do
  {:scripted_provider, provider} ->
    TailReplay.event(:ready)

    OrderDesk.ScriptedProvider.say(
      provider,
      "Check order one hundred twenty three. Actually, I meant one hundred twenty four. No, sorry, go back to one hundred twenty three"
    )

    OrderDesk.ScriptedProvider.delegate(provider, "tail-replay")
    TailReplay.event(:task_submitted)
    result = TailReplay.context()
    IO.puts("RESULT: " <> result.content)
    Process.sleep(100)
    IO.inspect(Parlora.status(session).interpretation, label: "BEFORE TAIL")
    OrderDesk.ScriptedProvider.say(provider, ".")

    receive do
      {:context, update} -> raise "Unexpected context after punctuation: #{update.content}"
    after
      3_500 -> :ok
    end

    status = Parlora.status(session)
    IO.inspect(status.interpretation, label: "AFTER TAIL")
    unless status.interpretation == :settled, do: raise("Punctuation reopened interpretation")

    unless Enum.all?(status.jobs, fn {_, j} ->
             j.status == :completed and j.delivery == :accepted
           end), do: raise("Result not accepted")

    IO.inspect(Enum.map(status.jobs, fn {_, job} -> {job.status, job.delivery} end),
      label: "JOBS"
    )

    File.write!(
      "/tmp/parlora-completed-tail-fixed-status.json",
      Jason.encode!(DiagnosticTrace.normalize(status), pretty: true)
    )

    Parlora.close(session, :cancel)
end

Process.sleep(100)
