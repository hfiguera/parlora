# Initialize shared Legion metadata before concurrent lifecycle/deadline tests.
# model/1 reuses an existing catalog instead of forcibly replacing it.
{:ok, _model} = LLMDB.model({:openai, "gpt-6-luna"})

# Jido scans dependency modules asynchronously after its application starts.
deadline = System.monotonic_time(:millisecond) + 60_000

await_discovery = fn await ->
  case Jido.Discovery.last_updated() do
    {:ok, _timestamp} ->
      :ok

    {:error, :not_initialized} ->
      if System.monotonic_time(:millisecond) >= deadline,
        do: raise("Jido fixture discovery did not finish within 60 seconds")

      Process.sleep(20)
      await.(await)
  end
end

await_discovery.(await_discovery)

# Controlled Legion HTTP fixtures use host-owned ReqLLM credentials.
Application.put_env(:req_llm, :openai_api_key, "private-key-and-prompt")

ExUnit.start(
  exclude: [:hardware, :live, :stability],
  # Observe asynchronous work independently of the short deadlines exercised by
  # individual fixtures, including when shared CI runners are under load.
  assert_receive_timeout: 5_000,
  capture_log: true
)
