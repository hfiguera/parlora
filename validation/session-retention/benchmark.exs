alias Parlora.{AdapterInit, Event, Limits}
alias Parlora.Session.{Retention, State}

if "--baseline" in System.argv() do
  Code.compiler_options(ignore_module_conflict: true)
  {source, 0} = System.cmd("git", ["show", "7fbbe96:lib/parlora/session.ex"])
  Code.compile_string(source, "lib/parlora/session.ex")
end

# Isolate transcript admission. A held policy task coalesces interpretation, as
# it does in a live session, so task scheduling cannot mask list traversal cost.
limits = %Limits{max_transcripts: 65_536, max_transcript_bytes: 64 * 1_048_576}

init = %AdapterInit{
  session_id: "benchmark",
  adapter_id: "provider",
  generation: 0,
  event_sink: self(),
  limits: limits
}

payload = %{speaker: :user, delta: "a short transcript delta", start_ms: nil, end_ms: nil}

event = %Event{
  source: :provider,
  adapter_id: init.adapter_id,
  generation: 0,
  type: :transcript_delta,
  payload: payload,
  observed_at_us: System.monotonic_time(:microsecond)
}

for entries <- [1_000, 20_000] do
  state = %State{
    id: "benchmark",
    init: init,
    limits: limits,
    health: Parlora.Session.Health.new(limits.max_records),
    context: %Parlora.ContextSnapshot{session_id: "benchmark", provider_generation: 0}
  }

  state = %{
    state
    | status: :ready,
      options: [provider: {init, []}],
      policy_task: %{ref: make_ref()}
  }

  state =
    Enum.reduce(1..entries, state, fn _, state ->
      {:ok, state} = Retention.append_transcript(state, payload)
      state
    end)

  samples =
    for _ <- 1..15 do
      :erlang.garbage_collect()
      {:reductions, before} = Process.info(self(), :reductions)

      {elapsed, final} =
        :timer.tc(fn ->
          Enum.reduce(1..1_000, state, fn _, state ->
            {:noreply, state} = Parlora.Session.handle_info({:parlora_event, event}, state)
            state
          end)
        end)

      {:reductions, after_count} = Process.info(self(), :reductions)
      true = final.context.revision == entries + 1_000
      {elapsed, after_count - before}
    end

  times = samples |> Enum.map(&elem(&1, 0)) |> Enum.sort()
  reductions = samples |> Enum.map(&elem(&1, 1)) |> Enum.sort()

  IO.puts(
    JSON.encode!(%{
      baseline: "--baseline" in System.argv(),
      initial_entries: entries,
      appended: 1_000,
      median_us: Enum.at(times, 7),
      median_reductions: Enum.at(reductions, 7)
    })
  )
end
