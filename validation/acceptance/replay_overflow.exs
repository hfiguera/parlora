# Offline diagnostic: replay retained timings against the production receive buffer.
# Expected outcome is the recorded overflow; this does not implement a fix.
alias Parlora.{AdapterInit, AudioFormat, Limits}
alias Parlora.Provider.OutputBuffer

evidence =
  __DIR__
  |> Path.join("results/6-interrupt-disconnect.json")
  |> File.read!()
  |> JSON.decode!()

failure =
  Enum.find(evidence["events"], fn event ->
    get_in(event, ["payload", "cause"]) == "output_overflow"
  end)["payload"]

events = failure["audio_trace"]["events"]
limits = %Limits{provider_audio_queue_bytes: failure["capacity_bytes"]}

init = %AdapterInit{
  limits: limits,
  audio_format: %AudioFormat{},
  session_id: "offline-overflow-replay",
  adapter_id: "provider",
  generation: 0,
  event_sink: self()
}

# The retained window starts with an empty read, so no missing initial backlog
# needs to be guessed even though the older trace history was truncated.
%{"kind" => "read", "bytes" => 0, "queue_bytes" => 0} = hd(events)

{queue, _sequence, received, removed, overflows} =
  Enum.reduce(events, {OutputBuffer.new(limits), 0, 0, 0, 0}, fn event,
                                                                 {queue, seq, input, output,
                                                                  errors} ->
    bytes = event["bytes"]
    at = event["at_us"]

    case event["kind"] do
      "read" ->
        {:ok, frames, next} = OutputBuffer.read(queue, limits.max_frame_bytes, limits, at)
        actual = Enum.reduce(frames, 0, &(byte_size(&1.data) + &2))
        true = actual == bytes
        true = next.bytes == event["queue_bytes"]
        {next, seq, input, output + actual, errors}

      "received" ->
        true = queue.bytes == event["queue_bytes"]

        case OutputBuffer.push(queue, :binary.copy(<<0>>, bytes), init, seq, at) do
          {:ok, {next, next_seq}} ->
            {next, next_seq, input + bytes, output, errors}

          {:error, %{code: :output_overflow}} ->
            true = event == List.last(events)
            true = queue.bytes == failure["queue_bytes"]
            true = bytes == failure["incoming_bytes"]
            {queue, seq, input + bytes, output, errors + 1}
        end
    end
  end)

1 = overflows
28_800 = received
3_840 = removed
20_160 = queue.bytes
24_960 = received - removed
arrivals = Enum.filter(events, &(&1["kind"] == "received"))
79_201 = List.last(arrivals)["at_us"] - hd(arrivals)["at_us"]

IO.puts("Reproduced: 600 ms received in 79.201 ms; 80 ms read; 520 ms required.")
IO.puts("20,160 queued + 4,800 incoming > 24,000 capacity; exact recorded overflow.")
