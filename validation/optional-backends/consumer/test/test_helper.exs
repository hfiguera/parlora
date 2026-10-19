if Application.fetch_env!(:optional_backend_consumer, :profile) == :legion do
  Application.put_env(:req_llm, :openai_api_key, "private-key-and-prompt")
  # Other profiles deliberately do not install LLMDB or the Legion fixture.
  {:ok, _model} = apply(LLMDB, :model, [{:openai, "gpt-6-luna"}])
end

if Application.fetch_env!(:optional_backend_consumer, :profile) == :jido do
  deadline = System.monotonic_time(:millisecond) + 60_000

  await_discovery = fn await ->
    case apply(Jido.Discovery, :last_updated, []) do
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
end

# Copied backend tests use the same asynchronous observation budget as the
# library suite, independently of their fixture execution deadlines.
ExUnit.start(capture_log: true, assert_receive_timeout: 5_000)
