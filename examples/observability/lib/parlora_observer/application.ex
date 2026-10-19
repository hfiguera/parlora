defmodule ParloraObserver.Application do
  use Application
  @impl true
  def start(_type, _args) do
    children = [
      {TelemetryMetricsPrometheus.Core, metrics: metrics()},
      ParloraObserver.Traces,
      {Bandit,
       plug: ParloraObserver.Metrics,
       ip: {0, 0, 0, 0},
       port: Application.fetch_env!(:parlora_observer, :metrics_port)}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end

  defp metrics do
    operations = [
      :session,
      :startup,
      :shutdown,
      :policy,
      :backend_queue,
      :backend,
      :delivery,
      :recovery,
      :interruption
    ]

    Enum.flat_map(operations, fn operation ->
      [
        Telemetry.Metrics.counter("parlora.#{operation}.stop.count", tags: [:outcome]),
        Telemetry.Metrics.distribution("parlora.#{operation}.stop.duration",
          unit: {:native, :millisecond},
          tags: [:outcome],
          reporter_options: [buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1000, 5000, 15000]]
        )
      ]
    end) ++
      [
        Telemetry.Metrics.last_value("parlora.provider.audio_received.queue_bytes"),
        Telemetry.Metrics.last_value("parlora.provider.audio_received.queue_duration_us",
          unit: {:microsecond, :millisecond}
        ),
        Telemetry.Metrics.last_value("parlora.provider.audio_read.oldest_age_us",
          unit: {:microsecond, :millisecond}
        ),
        Telemetry.Metrics.sum("parlora.provider.audio_received.dropped_bytes"),
        Telemetry.Metrics.last_value("parlora.audio.playout.playback_target_ms"),
        Telemetry.Metrics.last_value("parlora.audio.playout.starvations"),
        Telemetry.Metrics.distribution("parlora.audio.tick.late_us",
          unit: {:microsecond, :millisecond},
          tags: [:direction],
          reporter_options: [buckets: [1, 5, 10, 25, 50, 100, 250]]
        ),
        Telemetry.Metrics.counter("parlora.runtime.event.count", tags: [:source, :type, :stage])
      ]
  end
end
