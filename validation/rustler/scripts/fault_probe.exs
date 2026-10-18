# Invoke only via verify_faults.py, which creates disposable BEAM processes.
"1" = System.fetch_env!("PARLORA_ISOLATED_FAULT_PROBE")
Logger.configure(level: :error)

case System.argv() do
  ["panic"] ->
    try do
      OpusProbe.inject_panic()
      raise "Expected a caught Rust panic"
    rescue
      error in ErlangError ->
        :nif_panicked = error.original
    end

    {:ok, codec} = OpusProbe.new(:encoder, 24_000, 1, 2048)
    {:ok, _} = OpusProbe.encode(codec, :binary.copy(<<0>>, 960), 480)
    :ok = OpusProbe.close(codec)
    IO.puts("PANIC_CAUGHT_BEAM_AND_CODEC_ALIVE")

  ["resource_panic"] ->
    {:ok, codec} = OpusProbe.new(:encoder, 24_000, 1, 2048)

    try do
      OpusProbe.inject_resource_panic(codec)
      raise "Expected a caught Rust panic"
    rescue
      error in ErlangError ->
        :nif_panicked = error.original
    end

    {:error, :poisoned} = OpusProbe.encode(codec, :binary.copy(<<0>>, 960), 480)
    :ok = OpusProbe.close(codec)
    :ok = OpusProbe.close(codec)
    IO.puts("POISONED_STATE_REJECTED_AND_RELEASED")

  ["abort"] ->
    IO.puts("ABOUT_TO_ABORT_DISPOSABLE_BEAM")
    OpusProbe.inject_abort()
    IO.puts("UNEXPECTED_ABORT_RETURN")
end
