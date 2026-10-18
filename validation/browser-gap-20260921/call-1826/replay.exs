# Run from the repository root with MIX_ENV=test mix run --no-start <this file>.
# Numeric arrival/tick replay, not recorded speech or a counterfactual whole call.
alias Parlora.{AudioFrame, AudioQueue, Playout}

Code.require_file("observed_playout.exs", __DIR__)

{baseline, 0} = System.cmd("git", ["show", "8e94f217c4f0091f5083382bb2de3c74d56d0c51:lib/parlora/playout.ex"])

Code.compile_string(
  String.replace(baseline, "defmodule Parlora.Playout do", "defmodule RecordedBaselinePlayout do")
)

defmodule RecordedGapReplay do
  def run(module, state, trace) do
    gap = trace["gap"]["measurements"]
    start = gap["started_at_us"]

    state = %{
      state
      | playing?: true,
        recovering?: false,
        waiting_since_us: nil,
        empty_since_us: nil
    }

    {_, queue, state} = module.take(state, %AudioQueue{}, 960, start)

    trace["events"]
    |> Enum.filter(&(&1["measurements"]["at_us"] > start and &1["kind"] in ["frame", "playout"]))
    |> Enum.reduce_while({queue, state, nil}, fn event, {queue, state, _} ->
      m = event["measurements"]

      if event["kind"] == "frame" do
        pcm = :binary.copy(<<1, 0>>, div(m["bytes"], 2))

        {:ok, queue} =
          AudioQueue.push(queue, AudioFrame.pcm(pcm, "numeric-replay", event["index"]))

        {:cont, {queue, state, nil}}
      else
        {_, next_queue, next} = module.take(state, queue, 960, m["at_us"])

        if next.source_bytes > state.source_bytes do
          result = %{
            gap_ms: (m["at_us"] - start) / 1000,
            queue_at_release_ms: queue.bytes / 48,
            target_ms: if(Map.get(next, :target_bytes), do: next.target_bytes / 48),
            reason: next.release_reason
          }

          {:halt, {next_queue, next, result}}
        else
          {:cont, {next_queue, next, nil}}
        end
      end
    end)
  end
end

traces =
  __DIR__
  |> Path.join("trace-excerpts.json")
  |> File.read!()
  |> Jason.decode!()
  |> Map.fetch!("gaps")

{_, results} =
  Enum.reduce(traces, {RecordedAdaptivePlayout.new(120, 9600), []}, fn trace,
                                                                       {history, results} ->
    {_, next, current} = RecordedGapReplay.run(RecordedAdaptivePlayout, history, trace)
    {_, _, fresh} = RecordedGapReplay.run(Playout, Playout.new(120, 9600), trace)

    {_, _, baseline} =
      RecordedGapReplay.run(
        RecordedBaselinePlayout,
        RecordedBaselinePlayout.new(120, 9600),
        trace
      )

    actual = trace["gap"]["measurements"]["duration_us"] / 1000

    if current == nil or abs(current.gap_ms - actual) > 0.001,
      do: raise("observed policy replay did not reproduce recorded gap")

    result = %{
      gap: trace["gap"]["report_index"],
      recorded_ms: actual,
      observed_policy: current,
      fixed_policy: fresh,
      previous_commit: baseline
    }

    {next, results ++ [result]}
  end)

IO.puts(Jason.encode!(%{results: results}, pretty: true))
