alias Parlora.{AdapterInit, AudioFormat, ContextUpdate, Event, ID, Limits}
alias Parlora.Providers.OpenAI

init = %AdapterInit{
  session_id: ID.new(),
  adapter_id: ID.new(),
  generation: 0,
  event_sink: self(),
  audio_format: %AudioFormat{},
  limits: %Limits{}
}

{:ok, provider} =
  OpenAI.start_link(init,
    api_key: Application.fetch_env!(:parlora, :example_api_key),
    instructions: "Keep replies brief. Speak English."
  )

receive do
  {:parlora_event, %Event{type: :ready}} -> IO.puts("GPT-Live ready")
  {:parlora_event, %Event{type: :failed}} -> raise "GPT-Live startup failed"
after
  15_000 -> raise "GPT-Live readiness timeout"
end

:ok =
  OpenAI.append_context(provider, %ContextUpdate{
    id: "smoke-greeting",
    kind: :instruction,
    content: "Speak first in English. Say hello from Parlora.",
    provider_generation: 0
  })

:ok =
  OpenAI.append_context(provider, %ContextUpdate{
    id: "smoke-oversize",
    kind: :quiet,
    content: String.duplicate("validation ", 1_000),
    provider_generation: 0
  })

deadline = System.monotonic_time(:millisecond) + 8_000

poll = fn poll, counters ->
  if System.monotonic_time(:millisecond) < deadline do
    {:ok, frames} = OpenAI.read_audio(provider, 9_600)

    counters =
      Map.update!(
        counters,
        :audio_bytes,
        &(&1 + Enum.sum(Enum.map(frames, fn frame -> byte_size(frame.data) end)))
      )

    counters =
      receive do
        {:parlora_event, %Event{type: type}} -> Map.update(counters, type, 1, &(&1 + 1))
      after
        5 -> counters
      end

    poll.(poll, counters)
  else
    counters
  end
end

counters = poll.(poll, %{audio_bytes: 0})
:ok = OpenAI.close(provider, "smoke-close", :validation)

receive do
  {:parlora_event, %Event{type: :closed, payload: payload}} ->
    IO.inspect(Map.take(payload, [:finalized?, :reason, :usage]), label: "Finalization")
after
  6_000 -> raise "Finalization event missing"
end

IO.inspect(counters, label: "Observations (no audio or transcript contents)")
GenServer.stop(provider)
if counters.audio_bytes == 0, do: raise("Greeting generated no observed audio")

if Map.get(counters, :context_rejected, 0) == 0,
  do: raise("Oversized append rejection not observed")
