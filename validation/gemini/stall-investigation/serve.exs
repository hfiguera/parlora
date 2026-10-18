# Run from the standalone OrderDesk directory through its private Keychain launcher.
Code.require_file("trace.exs", __DIR__)
path = System.fetch_env!("PARLORA_STALL_TRACE_PATH")

options =
  case System.get_env("PARLORA_STALL_RECORD_PCM_ONCE") do
    nil -> []
    pcm_path -> [record_pcm_once: pcm_path]
  end

{:ok, _} = ParloraGeminiStallTrace.start(path, options)
OrderDesk.BrowserServer.run()
