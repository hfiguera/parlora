# Development-only launch with bounded lifecycle metadata capture.
Code.require_file(Path.join(__DIR__, "trace.exs"))
{:ok, _} = ParloraGrokCorrectionTrace.start(System.fetch_env!("GROK_TRACE_OUTPUT"))
OrderDesk.BrowserServer.run()
