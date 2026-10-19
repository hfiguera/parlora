Code.require_file("session.exs", __DIR__)
id = ParloraObserver.Demo.run()
IO.puts("Session ID: #{id}")
IO.puts("Offline session completed. Metrics: http://localhost:19100/metrics")

IO.puts(
  "VictoriaMetrics: http://localhost:18428/vmui/ — VictoriaTraces: http://localhost:19428/select/vmui/"
)

# Keep the host up so the Collector can scrape and the SDK can export asynchronously.
Process.sleep(:infinity)
