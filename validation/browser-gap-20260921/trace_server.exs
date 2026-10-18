Code.require_file("trace_recorder.exs", __DIR__)

{:ok, _trace} = BrowserAudioTrace.start_link(System.fetch_env!("PARLORA_AUDIO_TRACE_DIR"))
OrderDesk.BrowserServer.run()
