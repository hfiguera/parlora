defmodule RecoveryWindowReplay do
  alias Parlora.{AudioFrame, AudioQueue}

  def run(policy, events) do
    playout = policy.new(120, 9600, playback_buffering: :adaptive)

    initial = %{
      playout: %{playout | playing?: true, target: %{playout.target | target_ms: 200}},
      queue: %AudioQueue{},
      staged: 0,
      received_at: nil,
      sequence: 0,
      packets: []
    }

    state = Enum.reduce(events, initial, &event(&1, &2, policy))

    state.packets
    |> Enum.reverse()
    |> Enum.take_while(&(not &1))
    |> length()
    |> Kernel.*(10_000)
  end

  defp event(%{"kind" => "audio_received", "at_us" => at}, state, _policy),
    do: %{state | received_at: at}

  defp event(%{"kind" => "audio_read", "metrics" => %{"bytes" => bytes}}, state, policy)
       when bytes > 0 do
    frame =
      AudioFrame.pcm(:binary.copy(<<1, 0>>, div(bytes, 2)), "source", state.sequence,
        timestamp_us: state.received_at,
        clock: :local_monotonic
      )

    {:ok, queue} = AudioQueue.push(state.queue, frame)

    %{
      state
      | queue: queue,
        playout: policy.observe(state.playout, frame),
        sequence: state.sequence + 1
    }
  end

  defp event(%{"kind" => "playout"}, %{staged: bytes} = state, _policy) when bytes > 0,
    do: %{state | staged: bytes - 480, packets: [true | state.packets]}

  defp event(%{"kind" => "playout", "at_us" => at}, state, policy) do
    {pcm, queue, playout} = policy.take(state.playout, state.queue, 960, at)
    source? = playout.source_bytes > state.playout.source_bytes

    %{
      state
      | queue: queue,
        playout: playout,
        staged: if(source?, do: byte_size(pcm) - 480, else: 0),
        packets: [source? | state.packets]
    }
  end

  defp event(_event, state, _policy), do: state
end

source = File.read!(Path.join(__DIR__, "reference.exs"))
windows = File.read!(Path.join(__DIR__, "windows.json")) |> Jason.decode!()

results =
  for ceiling <- [20, 40, 50, 60, 80, 120] do
    policy = Module.concat(["WindowRecovery#{ceiling}"])

    candidate =
      source
      |> String.replace("defmodule RecoveryWaitReference do", "defmodule #{inspect(policy)} do")
      |> String.replace(
        "maximum = min(shortage + 20_000, cap)",
        "maximum = min(shortage + 20_000, cap)\n" <>
          "    maximum = if state.target && shortage <= cap, do: min(maximum, #{ceiling * 1_000}), else: maximum"
      )

    Code.compile_string(candidate)

    for window <- windows do
      silence = RecoveryWindowReplay.run(policy, window["events"])

      if ceiling == 120 && silence != window["expected_silence_us"],
        do: raise("Reference did not reproduce captured gap #{window["gap"]}")

      %{ceiling_ms: ceiling, gap_id: window["gap"], inserted_silence_us: silence}
    end
  end

report = %{
  description:
    "Isolated empty-queue windows with the observed 200 ms learned target. Actual read/render timings, synthetic PCM. Reference must reproduce the measured 190/180 ms gaps. This truncates subsequent playback; use comparison.json.gz for whole-stream safety and gap counts.",
  results: List.flatten(results)
}

File.write!(
  Path.join(__DIR__, "window-comparison.json"),
  Jason.encode!(report, pretty: true) <> "\n"
)

IO.puts(Jason.encode!(report))
